#!/usr/bin/ucode
"use strict";

import { readfile } from "fs";
import { cursor } from "uci";

const config_name = "xray_core";
const section_ref = ARGV[0];
const payload_file = ARGV[1];

function current_time() {
    return clock()[0];
}

function b64url_decode(s) {
    s = trim(replace(replace(replace(replace(s || "", "\n", ""), "\r", ""), "-", "+"), "_", "/"));
    while (length(s) % 4 != 0) {
        s += "=";
    }
    return b64dec(s);
}

function hex_value(c) {
    return index("0123456789abcdef", lc(c));
}

function url_decode(s) {
    let result = "";
    s = s || "";
    for (let i = 0; i < length(s); i++) {
        const c = substr(s, i, 1);
        if (c == "%" && i + 2 < length(s)) {
            const hi = hex_value(substr(s, i + 1, 1));
            const lo = hex_value(substr(s, i + 2, 1));
            if (hi >= 0 && lo >= 0) {
                result += chr(hi * 16 + lo);
                i += 2;
                continue;
            }
        }
        result += c == "+" ? " " : c;
    }
    return result;
}

function last_index(s, needle) {
    let result = -1;
    const nlen = length(needle);
    for (let i = 0; i <= length(s) - nlen; i++) {
        if (substr(s, i, nlen) == needle) {
            result = i;
        }
    }
    return result;
}

function parse_link(raw) {
    raw = trim(raw || "");
    const scheme_end = index(raw, "://");
    if (scheme_end < 1) {
        return null;
    }

    const scheme = lc(substr(raw, 0, scheme_end));
    let rest = substr(raw, scheme_end + 3);
    let fragment = "";
    let query = "";

    const fragment_start = index(rest, "#");
    if (fragment_start >= 0) {
        fragment = url_decode(substr(rest, fragment_start + 1));
        rest = substr(rest, 0, fragment_start);
    }

    const query_start = index(rest, "?");
    if (query_start >= 0) {
        query = substr(rest, query_start + 1);
        rest = substr(rest, 0, query_start);
    }

    return {
        scheme: scheme,
        body: rest,
        query: parse_query(query),
        name: fragment,
        raw: raw
    };
}

function parse_query(q) {
    let result = {};
    if (!q) {
        return result;
    }
    for (let part in split(q, "&")) {
        if (part == "") {
            continue;
        }
        const kv = split(part, "=", 2);
        result[url_decode(kv[0])] = url_decode(kv[1] || "");
    }
    return result;
}

function parse_authority(authority) {
    const at = last_index(authority, "@");
    let user = "";
    let hostport = authority;
    if (at >= 0) {
        user = substr(authority, 0, at);
        hostport = substr(authority, at + 1);
    }

    let host = "";
    let port = "";
    if (substr(hostport, 0, 1) == "[") {
        const end = index(hostport, "]");
        if (end < 0) {
            return null;
        }
        host = substr(hostport, 1, end - 1);
        if (substr(hostport, end + 1, 1) == ":") {
            port = substr(hostport, end + 2);
        }
    } else {
        const colon = last_index(hostport, ":");
        if (colon < 0) {
            return null;
        }
        host = substr(hostport, 0, colon);
        port = substr(hostport, colon + 1);
    }

    if (!host || !port) {
        return null;
    }

    return {
        user: url_decode(user),
        host: url_decode(host),
        port: port
    };
}

function split_nonempty(s, sep) {
    let result = [];
    for (let item in split(s || "", sep)) {
        item = trim(item);
        if (item != "") {
            push(result, item);
        }
    }
    return result;
}

function normalize_transport(t) {
    t = lc(t || "tcp");
    if (t == "raw") {
        return "tcp";
    }
    if (t == "kcp") {
        return "mkcp";
    }
    if (t == "http") {
        return "h2";
    }
    if (t == "xhttp") {
        return "splithttp";
    }
    if (t == "ws" || t == "grpc" || t == "h2" || t == "quic" || t == "mkcp" || t == "splithttp" || t == "httpupgrade" || t == "hysteria") {
        return t;
    }
    return "tcp";
}

function truthy_param(v) {
    v = lc(v || "");
    return v == "1" || v == "true" || v == "yes";
}

function apply_security(server, protocol, params, default_security) {
    let security = lc(params.security || params.tls || default_security || "none");
    if (security == "xtls") {
        security = "tls";
    }
    if (security != "tls" && security != "reality") {
        security = "none";
    }

    server[protocol + "_tls"] = security;

    if (security == "tls") {
        server[protocol + "_tls_host"] = params.sni || params.serverName || params.peer || "";
        server[protocol + "_tls_insecure"] = truthy_param(params.allowInsecure || params.insecure || params["skip-cert-verify"]) ? "1" : "0";
        if (params.fp || params.fingerprint) {
            server[protocol + "_tls_fingerprint"] = params.fp || params.fingerprint;
        }
        if (params.alpn) {
            server[protocol + "_tls_alpn"] = split_nonempty(params.alpn, ",");
        }
    } else if (security == "reality") {
        server[protocol + "_reality_fingerprint"] = params.fp || params.fingerprint || "chrome";
        server[protocol + "_reality_server_name"] = params.sni || params.serverName || "";
        server[protocol + "_reality_public_key"] = params.pbk || params.publicKey || "";
        server[protocol + "_reality_short_id"] = params.sid || params.shortId || "";
        server[protocol + "_reality_spider_x"] = params.spx || params.spiderX || "";
    }
}

function apply_transport(server, transport, params, fake_header) {
    server.transport = normalize_transport(transport);

    if (server.transport == "tcp") {
        server.tcp_guise = fake_header || "none";
        if (server.tcp_guise == "http") {
            server.http_host = split_nonempty(params.host || "", ",");
            server.http_path = split_nonempty(params.path || "/", ",");
        }
    } else if (server.transport == "ws") {
        server.ws_host = params.host || "";
        server.ws_path = params.path || "/";
    } else if (server.transport == "grpc") {
        server.grpc_service_name = params.serviceName || params.service_name || params.path || "";
        server.grpc_multi_mode = params.mode == "multi" ? "1" : "0";
    } else if (server.transport == "h2") {
        server.h2_host = split_nonempty(params.host || "", ",");
        server.h2_path = params.path || "/";
    } else if (server.transport == "splithttp") {
        server.splithttp_host = params.host || "";
        server.splithttp_path = params.path || "/";
    } else if (server.transport == "httpupgrade") {
        server.httpupgrade_host = params.host || "";
        server.httpupgrade_path = params.path || "/";
    } else if (server.transport == "mkcp") {
        server.mkcp_guise = fake_header || "none";
        if (params.seed) {
            server.mkcp_seed = params.seed;
        }
    } else if (server.transport == "quic") {
        server.quic_security = params.quicSecurity || "none";
        server.quic_key = params.key || "";
        server.quic_guise = fake_header || "none";
    }
}

function base_server(name, auth, authority) {
    return {
        alias: name || `${authority.host}:${authority.port}`,
        server: authority.host,
        server_port: authority.port,
        username: name || "",
        password: auth,
        domain_strategy: "UseIP",
        dialer_proxy: "disabled"
    };
}

function parse_vmess(link) {
    const decoded = b64url_decode(link.body);
    if (!decoded) {
        return null;
    }

    let item = null;
    try {
        item = json(decoded);
    } catch (e) {
        return null;
    }

    if (type(item) != "object" || !item.add || !item.port || !item.id) {
        return null;
    }

    let server = {
        alias: link.name || item.ps || `${item.add}:${item.port}`,
        server: item.add,
        server_port: item.port,
        username: link.name || item.ps || "",
        password: item.id,
        protocol: "vmess",
        vmess_security: item.scy || item.security || "auto",
        alter_id: item.aid || "0",
        domain_strategy: "UseIP",
        dialer_proxy: "disabled"
    };

    apply_transport(server, item.net || "tcp", {
        host: item.host || "",
        path: item.path || "",
        serviceName: item.path || "",
        seed: item.path || "",
        quicSecurity: item.security || "none",
        key: item.key || ""
    }, item.type || "none");
    apply_security(server, "vmess", {
        security: item.tls || "none",
        sni: item.sni || item.host || "",
        alpn: item.alpn || "",
        fp: item.fp || ""
    }, "none");

    return server;
}

function parse_vless_or_trojan(link, protocol) {
    const authority = parse_authority(link.body);
    if (!authority) {
        return null;
    }

    let server = base_server(link.name, authority.user, authority);
    server.protocol = protocol;
    if (protocol == "vless") {
        server.vless_encryption = link.query.encryption || "none";
        if (link.query.flow) {
            if (link.query.security == "reality") {
                server.vless_flow_reality = link.query.flow;
            } else {
                server.vless_flow_tls = link.query.flow;
            }
        }
    }

    apply_transport(server, link.query.type || "tcp", link.query, link.query.headerType || "none");
    apply_security(server, protocol, link.query, protocol == "trojan" ? "tls" : "none");
    return server;
}

function parse_shadowsocks(link) {
    let body = link.body;
    const at = last_index(body, "@");
    if (at < 0) {
        const decoded = b64url_decode(body);
        if (!decoded) {
            return null;
        }
        body = decoded;
    } else {
        const userinfo = substr(body, 0, at);
        const decoded = b64url_decode(userinfo);
        if (decoded) {
            body = decoded + substr(body, at);
        }
    }

    const authority = parse_authority(body);
    if (!authority) {
        return null;
    }

    const colon = index(authority.user, ":");
    if (colon < 1) {
        return null;
    }

    let server = base_server(link.name, url_decode(substr(authority.user, colon + 1)), authority);
    server.protocol = "shadowsocks";
    server.shadowsocks_security = url_decode(substr(authority.user, 0, colon));
    server.shadowsocks_tls = "none";
    server.transport = "tcp";

    if (link.query.plugin) {
        const plugin = link.query.plugin;
        if (index(plugin, "v2ray-plugin") == 0 || index(plugin, "xray-plugin") == 0) {
            let params = {};
            for (let part in split(plugin, ";")) {
                const kv = split(part, "=", 2);
                if (length(kv) == 2) {
                    params[kv[0]] = kv[1];
                } else {
                    params[kv[0]] = "1";
                }
            }
            if (params.mode == "websocket" || params.mode == "ws") {
                apply_transport(server, "ws", {
                    host: params.host || "",
                    path: params.path || "/"
                }, "none");
            }
            if (params.tls == "1" || params.tls == "true" || params.tls == "tls") {
                apply_security(server, "shadowsocks", {
                    security: "tls",
                    sni: params.host || ""
                }, "tls");
            }
        }
    }

    return server;
}

function parse_hysteria(link) {
    const authority = parse_authority(link.body);
    if (!authority) {
        return null;
    }

    let server = base_server(link.name, authority.user, authority);
    server.protocol = "hysteria";
    server.transport = "hysteria";
    server.hysteria_tls = "tls";
    server.hysteria_tls_host = link.query.sni || link.query.peer || "";
    server.hysteria_tls_insecure = truthy_param(link.query.insecure || link.query["skip-cert-verify"]) ? "1" : "0";
    if (link.query.upmbps || link.query.up) {
        server.hysteria_up_mbps = link.query.upmbps || link.query.up;
    }
    if (link.query.downmbps || link.query.down) {
        server.hysteria_down_mbps = link.query.downmbps || link.query.down;
    }
    if (link.query.alpn) {
        server.hysteria_tls_alpn = split_nonempty(link.query.alpn, ",");
    }
    return server;
}

function parse_server(raw) {
    const link = parse_link(raw);
    if (!link) {
        return null;
    }

    if (link.scheme == "vmess") {
        return parse_vmess(link);
    }
    if (link.scheme == "vless") {
        return parse_vless_or_trojan(link, "vless");
    }
    if (link.scheme == "trojan") {
        return parse_vless_or_trojan(link, "trojan");
    }
    if (link.scheme == "ss") {
        return parse_shadowsocks(link);
    }
    if (link.scheme == "hysteria2" || link.scheme == "hy2") {
        return parse_hysteria(link);
    }

    return null;
}

function filter_values(v) {
    if (type(v) == "array") {
        return filter(v, item => trim(item || "") != "");
    }
    if (v) {
        return [v];
    }
    return [];
}

function filter_match(name, include, exclude) {
    const n = lc(name || "");
    for (let f in exclude) {
        if (index(n, lc(f)) >= 0) {
            return false;
        }
    }
    if (length(include) == 0) {
        return true;
    }
    for (let f in include) {
        if (index(n, lc(f)) >= 0) {
            return true;
        }
    }
    return false;
}

function hash_string(s) {
    let h = 5381;
    for (let i = 0; i < length(s); i++) {
        h = (h * 33 + ord(s, i)) % 2147483647;
    }
    return sprintf("%x", h);
}

function sanitize_name(s) {
    s = lc(s || "node");
    let result = "";
    for (let i = 0; i < length(s); i++) {
        const c = substr(s, i, 1);
        if (match(c, /^[a-z0-9_]$/)) {
            result += c;
        } else {
            result += "_";
        }
    }
    result = trim(result, "_");
    if (result == "") {
        result = "node";
    }
    if (match(substr(result, 0, 1), /^[0-9]$/)) {
        result = "n_" + result;
    }
    return substr(result, 0, 32);
}

function section_name(source, server) {
    const identity = `${source}|${server.alias}|${server.protocol}|${server.server}|${server.server_port}`;
    return substr(`sub_${sanitize_name(source)}_${sanitize_name(server.alias)}_${hash_string(identity)}`, 0, 64);
}

function subscription_id(subscription) {
    if (subscription.subscription_id) {
        return subscription.subscription_id;
    }
    return `sub_${hash_string(`${subscription[".name"]}|${subscription.url || ""}|${current_time()}`)}`;
}

function normalize_value(v) {
    if (type(v) == "array") {
        return sprintf("%.J", v);
    }
    return `${v || ""}`;
}

function should_store_value(v) {
    return !(v == null || v == "" || (type(v) == "array" && length(v) == 0));
}

function section_equals(section, desired) {
    for (let k in keys(desired)) {
        if (normalize_value(section[k]) != normalize_value(desired[k])) {
            return false;
        }
    }

    for (let k in keys(section)) {
        if (substr(k, 0, 1) == ".") {
            continue;
        }
        if (!should_store_value(desired[k]) && should_store_value(section[k])) {
            return false;
        }
    }

    return true;
}

function is_referenced(config, server_name) {
    for (let section in values(config)) {
        for (let k in keys(section)) {
            if (substr(k, 0, 1) == ".") {
                continue;
            }
            const v = section[k];
            if (type(v) == "array") {
                if (index(v, server_name) >= 0) {
                    return true;
                }
            } else if (`${v}` == server_name) {
                return true;
            }
        }
    }
    return false;
}

function set_section(ctx, name, desired) {
    ctx.delete(config_name, name);
    ctx.set(config_name, name, "servers");
    for (let k in keys(desired)) {
        const v = desired[k];
        if (!should_store_value(v)) {
            continue;
        }
        ctx.set(config_name, name, k, v);
    }
}

function decode_subscription_payload(payload) {
    payload = trim(payload || "");
    if (index(payload, "://") >= 0) {
        return payload;
    }
    const decoded = b64url_decode(payload);
    if (decoded && index(decoded, "://") >= 0) {
        return decoded;
    }
    return payload;
}

function main() {
    if (!section_ref || !payload_file) {
        die("usage: subscription_import.uc <subscription-section> <payload-file>");
    }

    const ctx = cursor();
    ctx.load(config_name);
    const subscription = ctx.get_all(config_name, section_ref);
    if (!subscription || subscription[".type"] != "subscription") {
        die(`subscription section not found: ${section_ref}`);
    }

    const source = subscription_id(subscription);
    if (!subscription.subscription_id) {
        ctx.set(config_name, subscription[".name"], "subscription_id", source);
    }
    const include = filter_values(subscription.include_filter);
    const exclude = filter_values(subscription.exclude_filter);
    const payload = decode_subscription_payload(readfile(payload_file, 1048576) || "");
    let desired = {};
    let imported = 0;
    let skipped = 0;

    for (let line in split(replace(payload, "\r", "\n"), "\n")) {
        line = trim(line);
        if (line == "" || substr(line, 0, 1) == "#") {
            continue;
        }

        let server = parse_server(line);
        if (!server || !server.protocol || !server.server || !server.server_port) {
            skipped++;
            continue;
        }

        if (!filter_match(server.alias, include, exclude)) {
            skipped++;
            continue;
        }

        server.subscription_managed = "1";
        server.subscription_source = source;
        server.subscription_node_name = server.alias;
        server.subscription_stale = "0";

        let name = section_name(source, server);
        if (desired[name]) {
            name = substr(`${name}_${hash_string(line)}`, 0, 64);
        }
        desired[name] = server;
        imported++;
    }

    const config = ctx.get_all(config_name) || {};
    let changed = false;
    for (let name in keys(desired)) {
        const old = config[name];
        if (!old || old[".type"] != "servers" || !section_equals(old, desired[name])) {
            set_section(ctx, name, desired[name]);
            changed = true;
        }
    }

    for (let name in keys(config)) {
        const section = config[name];
        if (section[".type"] != "servers" || section.subscription_managed != "1" || section.subscription_source != source || desired[name]) {
            continue;
        }
        if (is_referenced(config, name)) {
            if (section.subscription_stale != "1") {
                ctx.set(config_name, name, "subscription_stale", "1");
                changed = true;
            }
        } else {
            ctx.delete(config_name, name);
            changed = true;
        }
    }

    ctx.set(config_name, subscription[".name"], "last_refresh", `${current_time()}`);
    ctx.set(config_name, subscription[".name"], "last_status", "ok");
    ctx.set(config_name, subscription[".name"], "last_message", sprintf("imported %d node(s), skipped %d line(s)", imported, skipped));
    ctx.commit(config_name);

    printf("changed=%d imported=%d skipped=%d\n", changed ? 1 : 0, imported, skipped);
}

main();
