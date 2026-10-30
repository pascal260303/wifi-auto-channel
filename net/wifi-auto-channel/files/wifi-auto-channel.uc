#!/usr/bin/ucode

'use strict';

import { connect as ubus_connect } from 'ubus';
import { cursor as uci_cursor } from 'uci';
import * as uloop from 'uloop';
import * as nl80211 from 'nl80211';
import * as fs from 'fs';
import {
	freq_to_channel, htmode_to_bw, get_oper_chwidth, get_center_freq1,
	build_phy_info, is_dfs, find_channel_group, channel_is_dfs,
	parse_phy_freq_line,
	compute_utilization, score_survey_channel, score_channel_group,
	find_best_channel, find_best_non_dfs_channel
} from 'wifi-auto-channel.channel';

const NL = nl80211.const;

let log_level = 1;
let ubus_conn = null;

function log(level, fmt, ...args) {
	if (level > log_level) return;
	let prefix = ['ERROR', 'INFO', 'DEBUG'][level] ?? 'TRACE';
	let msg = sprintf('[%s] ' + fmt, prefix, ...args);
	system(['logger', '-t', 'wifi-auto-channel', '-p',
		level == 0 ? 'daemon.err' : 'daemon.notice', msg]);
	if (log_level >= 2)
		printf('%s\n', msg);
}

function get_phy_freqs(phy_name) {
	let freqs = [];
	let pipe = fs.popen(sprintf('iw phy %s info 2>/dev/null', phy_name), 'r');
	if (!pipe) return null;

	let line;
	while ((line = pipe.read('line')) != null) {
		let entry = parse_phy_freq_line(line);
		if (entry)
			push(freqs, entry);
	}
	pipe.close();
	return length(freqs) ? freqs : null;
}

function discover_radios() {
	let radios = {};
	let ws = ubus_conn.call('network.wireless', 'status');
	if (!ws) return radios;

	for (let name in ws) {
		let r = ws[name];
		if (r.disabled) continue;

		let phy = null;
		let ifaces = [];
		for (let iface in (r.interfaces ?? [])) {
			let ifname = iface.ifname;
			if (ifname) {
				if (!phy)
					phy = trim(fs.readfile(`/sys/class/net/${ifname}/phy80211/name`));
				push(ifaces, ifname);
			}
		}
		if (!phy || !length(ifaces)) continue;

		let phy_freqs = get_phy_freqs(phy);
		let phy_info = phy_freqs ? build_phy_info(phy_freqs) : null;

		radios[name] = {
			phy: phy,
			ifaces: ifaces,
			band: r.config?.band,
			htmode: r.config?.htmode ?? 'HT20',
			bw: htmode_to_bw(r.config?.htmode ?? 'HT20'),
			country: r.config?.country,
			phy_info: phy_info,
		};
	}
	return radios;
}

function get_survey(ifname) {
	let res = nl80211.request(NL.NL80211_CMD_GET_SURVEY, NL.NLM_F_DUMP,
		{ dev: ifname });
	if (!res) return {};

	let survey = {};
	for (let entry in res) {
		let si = entry.survey_info;
		if (!si || !si.frequency) continue;
		survey[si.frequency] = {
			freq: si.frequency,
			noise: si.noise ?? -100,
			time: si.time ?? 0,
			time_busy: si.time_busy ?? 0,
			time_rx: si.time_rx ?? 0,
			time_tx: si.time_tx ?? 0,
			in_use: si.in_use ?? false,
		};
	}
	return survey;
}

function get_channel_info(phy_iface) {
	let status = ubus_conn.call('hostapd.' + phy_iface, 'get_status');
	if (!status) return null;

	return {
		freq: status.freq,
		channel: status.channel,
		cac_active: status.dfs?.cac_active ?? false,
	};
}

function get_current_utilization(ifname, freq) {
	let survey = get_survey(ifname);
	let entry = survey[freq];
	if (!entry || !entry.time) return null;

	return {
		time: entry.time,
		time_busy: entry.time_busy,
		time_rx: entry.time_rx,
		time_tx: entry.time_tx,
	};
}

function do_switch(radio_name, phy, target, bw) {
	let params = {
		phy: phy,
		frequency: target.freq,
		center_freq1: target.center_freq1 ?? get_center_freq1(target.freq, bw),
		oper_chwidth: get_oper_chwidth(bw),
		csa_count: 10,
	};

	log(1, '%s: switching to channel %d (%d MHz), center=%d, bw=%d',
		radio_name, freq_to_channel(target.freq), target.freq,
		params.center_freq1, bw);

	let ret = ubus_conn.call('hostapd', 'switch_channel', params);
	if ((ret === false || ret === null) && ubus_conn.error()) {
		log(0, '%s: switch_channel failed: %s', radio_name, ubus_conn.error());
		return false;
	}

	log(1, '%s: channel switch initiated', radio_name);
	return true;
}

function trigger_active_scan(ifname) {
	log(2, 'triggering active scan on %s', ifname);
	system(['iw', 'dev', ifname, 'scan', 'trigger']);
}

function load_history(radio_name) {
	let path = sprintf('/tmp/wifi-auto-channel/%s.json', radio_name);
	let data = fs.readfile(path);
	if (!data) return {};
	try {
		return json(data) ?? {};
	} catch(e) {
		return {};
	}
}

function save_history(radio_name, history) {
	fs.mkdir('/tmp/wifi-auto-channel');
	let path = sprintf('/tmp/wifi-auto-channel/%s.json', radio_name);
	fs.writefile(path, sprintf('%J\n', history));
}

function update_history(radio_name, history, util_pct) {
	let now = time();
	let lt = localtime(now);
	let date = sprintf('%04d-%02d-%02d', lt.year, lt.mon, lt.mday);
	let hour = sprintf('%d', lt.hour);

	if (!history[date])
		history[date] = {};

	let h = history[date];
	if (!h[hour]) {
		h[hour] = { sum: 0, count: 0 };
	}
	h[hour].sum += util_pct;
	h[hour].count += 1;

	let cutoff_lt = localtime(now - 7 * 86400);
	let cutoff = sprintf('%04d-%02d-%02d', cutoff_lt.year, cutoff_lt.mon, cutoff_lt.mday);
	for (let d in keys(history)) {
		if (d < cutoff)
			delete history[d];
	}
}

function load_config() {
	let c = uci_cursor();
	let global = {};
	let radios = {};

	global.enabled = +(c.get('wifi-auto-channel', 'global', 'enabled') ?? 1);
	log_level = +(c.get('wifi-auto-channel', 'global', 'log_level') ?? 1);

	c.foreach('wifi-auto-channel', 'radio', (s) => {
		radios[s['.name']] = {
			enabled: +(s.enabled ?? 0),
			check_interval: +(s.check_interval ?? 300),
			util_threshold: +(s.util_threshold ?? 50),
			sustained_count: +(s.sustained_count ?? 3),
			improvement_threshold: +(s.improvement_threshold ?? 30),
			cooldown: +(s.cooldown ?? 3600),
			dfs_allowed: +(s.dfs_allowed ?? 1),
			dfs_min_improvement: +(s.dfs_min_improvement ?? 50),
			active_scan: +(s.active_scan ?? 0),
			prefer_non_dfs: +(s.prefer_non_dfs ?? 0),
			non_dfs_margin: +(s.non_dfs_margin ?? 15),
		};
	});

	return { global, radios };
}

function main() {
	uloop.init();

	ubus_conn = ubus_connect();
	if (!ubus_conn) {
		log(0, 'failed to connect to ubus');
		exit(1);
	}

	let config = load_config();
	if (!config.global.enabled) {
		log(1, 'disabled in config, exiting');
		exit(0);
	}

	let hw_radios = discover_radios();
	log(1, 'discovered radios: %s', join(', ', keys(hw_radios)));

	let state = {};

	for (let name in hw_radios) {
		let rc = config.radios[name];
		if (!rc || !rc.enabled) {
			log(2, '%s: not enabled in config, skipping', name);
			continue;
		}

		let hw = hw_radios[name];
		let primary_iface = hw.ifaces[0];
		let chan_info = get_channel_info(primary_iface);
		let prev_survey = chan_info ? get_current_utilization(primary_iface, chan_info.freq) : null;

		let n_freqs = hw.phy_info ? length(keys(hw.phy_info.freqs)) : 0;
		log(1, '%s: monitoring phy=%s iface=%s htmode=%s bw=%d band=%s freqs=%d',
			name, hw.phy, primary_iface, hw.htmode, hw.bw, hw.band, n_freqs);

		state[name] = {
			config: rc,
			hw: hw,
			primary_iface: primary_iface,
			samples: [],
			prev_survey: prev_survey,
			last_switch: 0,
			avoided: [],
			history: load_history(name),
			consecutive_high: 0,
		};
	}

	if (!length(keys(state))) {
		log(1, 'no radios to monitor, exiting');
		exit(0);
	}

	let min_interval = 300;
	for (let name in state)
		if (state[name].config.check_interval < min_interval)
			min_interval = state[name].config.check_interval;

	let t;

	function check_channels() {
		for (let name in state) {
			let s = state[name];
			let rc = s.config;

			let chan_info = get_channel_info(s.primary_iface);
			if (!chan_info || chan_info.cac_active) {
				log(2, '%s: skipping check (cac_active or no data)', name);
				continue;
			}

			let cur_survey = get_current_utilization(s.primary_iface, chan_info.freq);
			if (!cur_survey) {
				log(2, '%s: no survey data for freq %d', name, chan_info.freq);
				continue;
			}

			let util_pct = 0;
			if (s.prev_survey)
				util_pct = compute_utilization(s.prev_survey, cur_survey);
			s.prev_survey = cur_survey;

			update_history(name, s.history, util_pct);
			if (time() % 3600 < min_interval)
				save_history(name, s.history);

			push(s.samples, util_pct);
			if (length(s.samples) > rc.sustained_count + 2)
				shift(s.samples);

			log(2, '%s: ch=%d util=%.1f%% (threshold=%d%%, consecutive=%d/%d)',
				name, chan_info.channel, util_pct,
				rc.util_threshold, s.consecutive_high, rc.sustained_count);

			if (util_pct >= rc.util_threshold)
				s.consecutive_high++;
			else
				s.consecutive_high = 0;

			if (rc.prefer_non_dfs &&
			    channel_is_dfs(chan_info.freq, s.hw.bw, s.hw.phy_info) &&
			    time() - s.last_switch >= rc.cooldown) {
				let survey = get_survey(s.primary_iface);
				if (length(keys(survey))) {
					let phy_info = s.hw.phy_info;
					let bw = s.hw.bw;
					let current_group = find_channel_group(chan_info.freq, bw);
					let current_score = current_group
						? score_channel_group(current_group, survey, chan_info.freq, phy_info, rc)
						: score_survey_channel(chan_info.freq, survey[chan_info.freq], chan_info.freq, phy_info);

					let best = find_best_non_dfs_channel(chan_info.freq, bw, survey, phy_info, rc, s.avoided);
					if (best && best.score >= current_score - rc.non_dfs_margin) {
						log(1, '%s: on DFS ch=%d (score=%.1f), non-DFS ch=%d (score=%.1f) within margin %d, switching off DFS',
							name, freq_to_channel(chan_info.freq), current_score,
							freq_to_channel(best.freq), best.score, rc.non_dfs_margin);

						if (do_switch(name, s.hw.phy, best, bw)) {
							s.last_switch = time();
							s.consecutive_high = 0;
							s.samples = [];
							s.prev_survey = null;
							continue;
						}
					} else if (best) {
						log(2, '%s: staying on DFS ch=%d, best non-DFS ch=%d score gap %.1f exceeds margin %d',
							name, freq_to_channel(chan_info.freq),
							freq_to_channel(best.freq), current_score - best.score, rc.non_dfs_margin);
					} else {
						log(2, '%s: on DFS channel but no non-DFS alternative available', name);
					}
				}
			}

			if (s.consecutive_high < rc.sustained_count)
				continue;

			let now = time();
			if (now - s.last_switch < rc.cooldown) {
				log(2, '%s: cooldown active (%ds remaining)',
					name, rc.cooldown - (now - s.last_switch));
				continue;
			}

			log(1, '%s: utilization sustained above %d%% for %d checks, evaluating alternatives',
				name, rc.util_threshold, s.consecutive_high);

			if (rc.active_scan)
				trigger_active_scan(s.primary_iface);

			let survey = get_survey(s.primary_iface);
			if (!length(keys(survey))) {
				log(0, '%s: no survey data available', name);
				continue;
			}

			let current_freq = chan_info.freq;
			let phy_info = s.hw.phy_info;
			let bw = s.hw.bw;

			let current_group = find_channel_group(current_freq, bw);
			let current_score = current_group
				? score_channel_group(current_group, survey, current_freq, phy_info, rc)
				: score_survey_channel(current_freq, survey[current_freq], current_freq, phy_info);

			let best = find_best_channel(current_freq, bw, survey, phy_info, rc, s.avoided);
			if (!best) {
				log(1, '%s: no suitable alternative channel found', name);
				continue;
			}

			let improvement = best.score - current_score;
			let threshold = rc.improvement_threshold;

			let target_has_dfs = false;
			if (best.group) {
				for (let f in best.group.freqs) {
					if (is_dfs(f, phy_info)) { target_has_dfs = true; break; }
				}
			} else {
				target_has_dfs = is_dfs(best.freq, phy_info);
			}
			if (target_has_dfs)
				threshold = rc.dfs_min_improvement;

			log(1, '%s: current ch=%d score=%.1f, best ch=%d score=%.1f, improvement=%.1f (need %d)',
				name, freq_to_channel(current_freq), current_score,
				freq_to_channel(best.freq), best.score, improvement, threshold);

			if (improvement < threshold) {
				log(1, '%s: improvement insufficient, staying on current channel', name);
				continue;
			}

			if (do_switch(name, s.hw.phy, best, bw)) {
				s.last_switch = now;
				s.consecutive_high = 0;
				s.samples = [];

				push(s.avoided, current_freq);
				if (length(s.avoided) > 3)
					shift(s.avoided);

				save_history(name, s.history);

				s.prev_survey = null;
			}
		}

		t.set(min_interval * 1000);
	}

	t = uloop.timer(30 * 1000, check_channels);

	log(1, 'wifi-auto-channel started, first check in 30s, check interval=%ds', min_interval);
	uloop.run();
}

main();
