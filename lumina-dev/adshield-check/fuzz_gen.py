# -*- coding: utf-8 -*-
"""Optional differential fuzzing of the iOS AdShield port against the shared reference engine (dev tool only).

Random messages and random timelines (observe / edit / delete / notAd / context / expect) are run through
adshield/ref/adshield.py; the outputs are written in the formats AdShieldCheck.swift reads, and the Swift port must
reproduce them exactly (every fingerprint field, every Decision field, and the serialize() bytes):

  python3 lumina-dev/adshield-check/fuzz_gen.py <path to the shared adshield/ dir> <out dir> <seed> 3000 400
  sh lumina-dev/adshield-check/run.sh --extra-fingerprints <out>/fuzz_fingerprints_0.json \
      --extra-fingerprints <out>/fuzz_fingerprints_1.json --extra-scenarios <out>/fuzz_scenarios.json

Outputs: fuzz_fingerprints_<n>.json (shape of vectors/fingerprint_vectors.json) and fuzz_scenarios.json (shape of
corpus/scenarios.json plus per-expect "decisions" and a final "blobHex"). Needs Python 3.9 (Unicode 13, like the
generator) and only the standard library. Everything is synthetic; never feed real chat content.
"""
import json
import os
import random
import sys

ADS = sys.argv[1]
OUT = sys.argv[2]
SEED = int(sys.argv[3])
NMSG = int(sys.argv[4])
NSC = int(sys.argv[5])
sys.path.insert(0, os.path.join(ADS, "ref"))
sys.path.insert(0, os.path.join(ADS, "gen"))
import adshield as A  # noqa: E402
import gen_vectors as GV  # noqa: E402

R = random.Random(SEED)
T = A.tables()
LOW = "abcdefghijklmnopqrstuvwxyz"
DIG = "0123456789"
TLDS = list(T.tlds) + ["bar", "is", "it", "xyz1", "comx", "c0m", "toolongtldnamehere"]
CJK_POOL = list("限時優惠加入會員專屬導師指導帶單名額有限今天天氣真不錯大家吃飯了嗎我家貓咪最近很喜歡睡在鍵盤上面週末要不要一起去爬山看看風景呢機會難得錯過私聊簡介頭像主頁訂單號碼編號價格元萬塊錢電話手機號聯繫方式微信飛機群組頻道公告報名活動抽獎口令收到謝謝老師好的了解辛苦了")
T2S = list(T.raw["t2s"].keys())
NOISE = ["🔥", "👉", "😀", "‍", "​", "️", "⃣", "ㅤ", "ａ", "Ｂ", "１", "２", "ᴀ", "ʙ", "а", "о", "е", "ㄱ", "ㅏ", "ㄳ", "가", "①", "❶", "⓵", "。", "！", "？", "；", "…", "，", "：", "＋", "➕", "\n", "\n\n", " ", "  ", "\t", "　", "ー", "丨", "丶", "đ", "ß", "İ", "ø", "ł", "́", "é", "🇹🇼", "👨‍👩‍👧", "\ud800" if False else "", "�"]


def rs(alpha, a, b):
    return "".join(R.choice(alpha) for _ in range(R.randint(a, b)))


def name(a=2, b=36):
    first = R.choice(LOW + LOW.upper() + DIG + "_")
    return first + rs(LOW + LOW.upper() + DIG + "_", a - 1, b - 1)


def label():
    k = R.random()
    if k < 0.7:
        return rs(LOW + DIG, 1, 10)
    if k < 0.85:
        return rs(LOW, 1, 4) + "-" + rs(LOW + DIG, 1, 5)
    if k < 0.9:
        return "-" + rs(LOW, 1, 4)
    if k < 0.95:
        return rs(LOW, 1, 4) + "-"
    return rs(LOW, 60, 66)


def host():
    labels = [label() for _ in range(R.randint(1, 4))]
    h = ".".join(labels) + "." + R.choice(TLDS)
    if R.random() < 0.1:
        h = "www." + h
    if R.random() < 0.05:
        h = ".".join(str(R.randint(0, 300)) for _ in range(4))
    if R.random() < 0.08:
        h = rs(LOW, 1, 5) + ":" + rs(LOW, 1, 4) + "@" + h
    if R.random() < 0.1:
        h += ":" + rs(DIG, 1, 7)
    if R.random() < 0.1:
        h = R.choice(["bit.ly", "t.cn", "youtu.be", "wa.me", "api.whatsapp.com", "twitter.com", "m.youtube.com",
                      "x.github.io", "foo.co.uk", "a.b.com.tw", "telegram.me", "fb.com", "lumina-test.example.org",
                      "lumina-org.github.io"])
    return h


def path():
    k = R.random()
    if k < 0.3:
        return ""
    p = "/" + "/".join(rs(LOW + DIG + "-._~%+!$&*,;=:@", 0, 8) for _ in range(R.randint(1, 3)))
    if R.random() < 0.4:
        qs = []
        for _ in range(R.randint(1, 4)):
            key = R.choice(["utm_source", "utm_x", "fbclid", "ref", "a", "b", "v", "id", "phone", "start", "k", "si", "t", "s"])
            val = R.choice(["", rs(LOW + DIG, 1, 6), "86138" + rs(DIG, 8, 8)])
            qs.append(key + ("=" + val if R.random() < 0.85 else ""))
        p += "?" + "&".join(qs)
    if R.random() < 0.15:
        p += "#" + rs(LOW, 1, 5)
    if R.random() < 0.2:
        p += R.choice(["/", "//", ".", ",", "!", "?", "*", ";", ":", ")"])
    return p


def frag_url():
    sch = R.choice(["http://", "https://", "HTTPS://", "Http://", "ftp://", "tg://", "htp://", "https:/", "", "", "hxxp://", "xhttps://"])
    if sch == "tg://":
        host_ = R.choice(["resolve", "join", "user", "openmessage", "msg_url", "resolve/", "/user"])
        q = R.choice(["?domain=" + name(3, 34), "?invite=" + rs(LOW + DIG, 0, 10), "?id=" + rs(DIG, 1, 10),
                      "?user_id=" + rs(DIG + "a", 1, 8), "?id=1&id=" + rs(DIG, 1, 6), "?domain=ab&domain=" + name(4, 10), ""])
        return sch + host_ + q
    return sch + host() + path()


def frag_tme():
    base = R.choice(["t.me", "T.ME", "t .me", "t. me", "t . me", "telegram.me", "telegram.dog", "www.t.me", "t.me ",
                     "t.dog", "telegram .me", "ｔ．ｍｅ", "t。me", "https://t.me", "http://telegram.me", "tme"])
    seg = R.choice(["+" + rs(LOW + DIG + "_-", 1, 12), "+" + rs(DIG, 3, 17), "joinchat/" + rs(LOW + DIG, 0, 8),
                    "addlist/" + rs(LOW, 1, 5), "c/" + rs(DIG, 1, 10) + "/" + rs(DIG, 1, 4), "s/" + name(2, 34),
                    name(2, 36), name(4, 12) + "/" + rs(DIG, 1, 4), "iv?url=x", "share/url?url=abc", "", "+", "/",
                    "proxy?server=a", name(4, 10) + "?start=" + rs(LOW, 1, 5)])
    sep = R.choice(["/", " /", "/", "/"])
    return base + sep + seg


def frag_sub():
    return name(2, 36) + R.choice([".t.me", ".t.me/", ".t.me/x", ".t.mex", ".t.me-", ".T.ME"]) + R.choice(["", path()])


def frag_email():
    local = rs(LOW + DIG + "._%+-", 1, 12)
    dom = ".".join(rs(LOW + DIG + "-", 1, 8) for _ in range(R.randint(1, 3)))
    tail = R.choice([".com", ".com.tw", ".co.uk", ".c0m", ".a", "." + rs(LOW, 2, 26), ".org.", ".io-x", ".com.x1", ""])
    return local + "@" + dom + tail


def frag_mention():
    return R.choice(["@", "@ ", "@@", "x@", "_@"]) + name(1, 36)


def digits_sep(n):
    out = []
    for i in range(n):
        if i and R.random() < 0.3:
            out.append(R.choice([" ", "-", ".", "  ", "/"]))
        out.append(R.choice(DIG))
    return "".join(out)


def frag_phone():
    k = R.random()
    if k < 0.3:
        return "+" + digits_sep(R.randint(5, 17))
    if k < 0.55:
        return "1" + R.choice(["", " ", "-", "."]) + R.choice("3456789012") + digits_sep(R.randint(8, 10))
    if k < 0.75:
        return "09" + digits_sep(R.randint(7, 9))
    return R.choice(["", "訂單號", "单号 ", "order ", "id:", "no.", "$", "us$", "rmb ", "价格"]) + digits_sep(R.randint(5, 16)) + \
        R.choice(["", "元", " usd", "đ", " dong", "vnd", "u", "uk", " 万", "$", "rp", "rs", "rsx"])


def frag_contact():
    kw, cls, kind = R.choice(T.keywords)
    pre = R.choice(["", "", "加", "加我", "加 我 ", "+", "加个", "我", "x", "1", "請"])
    gap = "".join(R.choice([":", "：", " ", "=", "@", "🔥", "-", "\n", "，", "~", "　"]) for _ in range(R.randint(0, 5)))
    acc = R.choice([name(1, 33), rs(DIG, 3, 12), "10.14.2", "2026-11-17", rs(LOW + DIG + "_-.", 2, 34), name(3, 8) + ".", rs(DIG, 5, 9) + "-"])
    return pre + kw + gap + acc


def frag_pointer():
    k = R.random()
    if k < 0.6:
        p = R.choice(T.pointer_cjk)
        pre = R.choice(["", "自", "隐", "隱", "不要", "別", "别猶豫", "不要錯過", "管理員不會主動", "秘", "親", "小心", "有需要", "x"])
        post = R.choice(["", "你", "了", "们", "了解", "他", "哦", "詳談"])
        return pre + p + post
    return R.choice(T.pointer_ascii).upper() if R.random() < 0.3 else R.choice(T.pointer_ascii) + R.choice(["", "!", " now", "x"])


def frag_number():
    return R.choice(["", "訂單", "編號：", "order#", "xorder,,,,,,", "order,,,,,,,", "tx ", "价格", "$", "rmb"]) + \
        R.choice([rs(DIG, 5, 12), "20261117", "19991231", "20261332", "1500000", "+1.500.000"]) + \
        R.choice(["", "đ", "元", " usd", "usdx", "u", "萬", "号", " "])


def frag_cjk():
    n = R.randint(1, 40)
    return "".join(R.choice(CJK_POOL + T2S[:200]) for _ in range(n))


def frag_noise():
    return "".join(R.choice(NOISE) for _ in range(R.randint(1, 4)))


def frag_ack():
    return R.choice(T.ack) + R.choice(["", "老师", "大家", "！", "啦"])


FRAGS = [frag_url, frag_tme, frag_sub, frag_email, frag_mention, frag_phone, frag_contact, frag_pointer,
         frag_number, frag_cjk, frag_cjk, frag_noise, frag_ack]


def random_text(max_frags=8):
    parts = []
    for _ in range(R.randint(0, max_frags)):
        parts.append(R.choice(FRAGS)())
        parts.append(R.choice(["", " ", "  ", "\n", "，", "。", ",", " - ", "!", "/", "@", ".", ":"]))
    s = "".join(parts)
    if R.random() < 0.15:
        para = frag_cjk() + frag_cjk()
        s = para + "\n" + s + "\n" + para
    if R.random() < 0.3:
        s = multiline_text()
    return crlf_variant(s)


def multiline_text():
    """v3: a price-list style text (short lines, blank / emoji / link-only separator lines) so content lines, the VAR
    family and BLOCK keys get exercised."""
    lines = []
    for _ in range(R.randint(1, 45)):
        k = R.random()
        if k < 0.55:
            lines.append(frag_cjk()[:R.randint(1, 20)] + R.choice(["", " " + rs(DIG, 1, 4) + "元", "：", " " + frag_number()]))
        elif k < 0.7:
            lines.append(R.choice(["", " ", "\t", "🔥🔥", "👉", "———", frag_url(), frag_tme(), frag_mention()]))
        elif k < 0.8:
            lines.append(R.choice(FRAGS)())
        else:
            lines.append(rs(LOW + " ", 1, 30))
    return "\n".join(lines)


def crlf_variant(s):
    """v3 §2.1: the same text with CR LF / lone CR / U+2028 line breaks now and then."""
    k = R.random()
    if k < 0.1:
        return s.replace("\n", "\r\n")
    if k < 0.13:
        return s.replace("\n", R.choice(["\r", "\r\r\n", "\u2028", "\n\r"]))
    return s


def edit_variant(t):
    """v3: a small edit of a template: add / remove / replace one line, add a short first line, or swap blocks."""
    lines = t.split("\n")
    k = R.random()
    if k < 0.25:
        lines.insert(0, R.choice(["丝滑提交：", "最新：", "更新", frag_cjk()[:6]]))
        if R.random() < 0.5:
            lines.insert(1, "")
    elif k < 0.45 and len(lines) > 1:
        del lines[R.randrange(len(lines))]
    elif k < 0.65:
        lines[R.randrange(len(lines))] = frag_cjk()[:R.randint(1, 16)]
    elif k < 0.8:
        lines.insert(R.randint(0, len(lines)), frag_cjk()[:R.randint(1, 12)])
    else:
        blocks = "\n".join(lines).split("\n\n")
        R.shuffle(blocks)
        return "\n\n".join(blocks)
    return "\n".join(lines)


def random_message(mid, date, sender=None):
    m = {"id": mid, "date": date}
    if sender is None:
        sender = {"id": R.choice([7001, 7002, 7003, 0, -1001234567890, -1009876543210, 8008]),
                  "role": R.choice(["member"] * 6 + ["admin", "creator", "anon_admin", "bot", "contact", "self", "channel"])}
        if R.random() < 0.6:
            sender["username"] = R.choice(["Spam_Bot1", "alice_member", "bob_member", "lumina_me", "deal_x88", "@Mixed_Case", "ab", name(2, 34)])
    m["sender"] = sender
    m["text"] = random_text()
    if R.random() < 0.25:
        ents = []
        for _ in range(R.randint(1, 3)):
            if R.random() < 0.5:
                ents.append({"type": "text_url", "url": R.choice([frag_url(), frag_tme(), "", "tg://user?id=" + rs(DIG, 1, 9)])})
            else:
                ents.append({"type": "mention_name", "userId": R.choice([sender["id"], 5, 6, 7, 0])})
        m["entities"] = ents
    if R.random() < 0.15:
        m["buttons"] = [R.choice([frag_url(), frag_tme(), "", "https://bit.ly/abc"]) for _ in range(R.randint(1, 2))]
    if R.random() < 0.3:
        kind = R.choice(["photo", "video", "document", "audio", "contact", "sticker", "gif", "voice", "round", "poll", "webpage", "paid"])
        media = {"kind": kind}
        if kind == "contact":
            if R.random() < 0.5:
                media["userId"] = R.choice([0, 5, 123456])
            if R.random() < 0.7:
                media["phone"] = R.choice(["+86 138 1234 5678", "0912-345-678", "123", "abc", "+1 (555) 010-9999", "１３８１２３４５６７８"])
        elif R.random() < 0.9:
            media["id"] = R.choice(["5000000001", "-4611686018427387904", "42", "9223372036854775807"])
        m["media"] = media
    if R.random() < 0.15:
        fk = R.choice(["channel", "user", "hidden"])
        fwd = {"fromKind": fk, "date": R.choice([0, 1794000000, 1795000000])}
        if R.random() < 0.7:
            fwd["fromId"] = R.choice([-1009876543210, -1002000000002, -1001111, 7001, 0])
        if R.random() < 0.6:
            fwd["postId"] = R.choice([0, 1, 77])
        if R.random() < 0.5:
            fwd["fromName"] = R.choice(["Some Channel", "張三", "ᴀʙᴄ 123"])
        if R.random() < 0.5:
            fwd["username"] = R.choice(["luminatest_ch", "bigsale", "news_ch"])
        m["forward"] = fwd
    for f in ("viaBot", "replyToMe", "mentionsMe", "pinned", "autoForward"):
        if R.random() < (0.12 if f in ("pinned", "autoForward") else 0.05):
            m[f] = True
    if R.random() < 0.15:
        m["replyTo"] = R.choice([1, 2, 99])
    if R.random() < 0.05:
        m["album"] = R.choice([111, 222])
    return m


def fp_expect(fp, key):
    return {
        "fold": fp.F, "foldNoLinks": fp.F_nolinks, "text": fp.T, "cjk": fp.Tcjk, "wlen": fp.wlen,
        "cjkCount": fp.cjk_count, "otherLetterCount": fp.letter_count, "paragraphs": fp.paragraphs,
        "links": [GV.link_json(l, ft, key) for l, ft in zip(fp.links, fp.link_features)],
        "strong": fp.strong, "weak": fp.weak, "mentionCount": fp.mention_count,
        "keys": [{"kind": A.KIND_NAME[k], "tag": A.KIND_TAG[k], "payload": p, "hash": A.hex64(h)} for k, p, h in fp.keys],
        "flags": fp.flags, "flagNames": GV.flag_names(fp.flags),
        "subsetLinks": [A.hex64(h) for h in fp.link_hashes], "pending": [A.hex64(h) for h in fp.pending],
        "resolvedStrong": fp.resolved_strong, "resolvedWeak": fp.resolved_weak,
        "resolvedFlags": fp.resolved_flags, "resolvedFlagNames": GV.flag_names(fp.resolved_flags),
        "senderKey": A.hex64(fp.sender_key), "store": fp.store, "endorsing": fp.endorsing,
        "contentLines": fp.content_lines, "blocks": fp.blocks, "privileged": fp.privileged,
    }


def gen_fingerprints():
    key = A.TEST_KEY
    contexts = [GV.ctx_json(), {"chatId": -1005550001, "type": "supergroup", "username": "", "linkedChannel": {"id": 0},
                                "description": "", "pinnedTexts": [], "adminsKnown": True, "memberHandles": [],
                                "selfUsername": ""}]
    for ci, ctxd in enumerate(contexts):
        ctx = A.ChatContext.from_json(ctxd)
        cases = []
        for i in range(NMSG):
            m = random_message(i + 1, 1795000000 + i)
            fp = A.fingerprint(m, ctx, key, known_handles=set())
            cases.append({"id": "fz%d-%d" % (ci, i), "description": "fuzz", "message": m, "expect": fp_expect(fp, key)})
        with open(os.path.join(OUT, "fuzz_fingerprints_%d.json" % ci), "w", encoding="utf-8") as f:
            json.dump({"tablesVersion": T.version, "algoVersion": A.ALGO_VERSION, "key": key.hex(), "context": ctxd, "cases": cases},
                      f, ensure_ascii=False)


def decision_tuple(d):
    return [d["state"], d["fold"], d["class"] or "", d["rule"] or "", d["occurrence"], d["groupSize"], d["replyToMe"]]


def gen_scenarios():
    base = 1794268800
    scenarios = []
    for si in range(NSC):
        ctxd = {"chatId": R.choice([-1001000000001, -42, 777]), "type": R.choice(["supergroup"] * 5 + ["group", "forum", "gigagroup"]),
                "username": R.choice(["lumina_demo_grp", ""]), "linkedChannel": {"id": R.choice([0, -1002000000002]), "username": "lumina_demo_ch"},
                "description": R.choice(["", "官網 https://lumina-demo.example.org 邀請 t.me/+DemoGroupInv"]),
                "pinnedTexts": R.choice([[], ["置頂：客服 @help_desk1 電話 +886 912 345 678"]]),
                "adminsKnown": R.random() < 0.9, "memberHandles": R.choice([[], ["me_demo_user"], ["spam_bot1", "deal_x88"]]),
                "selfUsername": R.choice(["", "lumina_me"])}
        settings = {}
        for k in ("exemptContacts", "exemptBots", "exemptReplies"):
            if R.random() < 0.15:
                settings[k] = False
        if R.random() < 0.5:
            settings["foldPrivilegedRepeats"] = True
        # templates and senders shared inside the scenario so clusters form
        templates = [random_text(6) for _ in range(R.randint(2, 6))]
        if R.random() < 0.5:
            templates += [multiline_text() for _ in range(R.randint(1, 3))]
        focused = R.random() < 0.4
        pure = ["".join(R.choice(CJK_POOL) for _ in range(R.randint(12, 30))) for _ in range(R.randint(1, 3))]
        senders = []
        for i in range(R.randint(2, 7)):
            s = {"id": 9000 + i, "role": R.choice(["member"] * 8 + ["admin", "bot", "contact", "self", "anon_admin", "creator", "channel"])}
            if s["role"] == "channel":
                s["id"] = R.choice([-1002000000002, -1004000000004])     # the linked channel, or another channel
            elif s["role"] == "anon_admin":
                s["id"] = ctxd["chatId"]
            if R.random() < 0.7:
                s["username"] = R.choice(["deal_x88", "spam_bot1", "user_%d" % i, "me_demo_user", "lumina_me", "U_%d" % i])
            senders.append(s)
        acct = A.AccountStore(user_id=424242, key=A.TEST_KEY)
        ctx = A.ChatContext.from_json(ctxd)
        chat = acct.chat(ctx.chat_id)
        events = []
        seen = []
        now = 0
        date = base + R.randint(0, 3600)
        next_id = 1
        for step in range(R.randint(4, 40)):
            k = R.random()
            if k < (0.9 if focused else 0.72) or not seen:
                date += R.choice([0, 60, 600, 3600, 4 * 3600, 20 * 3600, 30 * 3600, 3 * 86400, -3600, -86400])
                date = max(date, 0)
                if R.random() < 0.15 and seen:
                    mid = R.choice(seen)            # edit / re-observe
                else:
                    mid = next_id
                    next_id += 1
                m = random_message(mid, date, R.choice(senders))
                if R.random() < 0.75:
                    m["text"] = R.choice(templates) + R.choice(["", "", " " + frag_cjk(), " " + rs(DIG, 1, 3)])
                    if R.random() < 0.35:
                        m["text"] = crlf_variant(edit_variant(m["text"]))
                if R.random() < 0.1 and ctxd["linkedChannel"]["id"]:
                    m["forward"] = {"fromKind": "channel", "fromId": ctxd["linkedChannel"]["id"], "postId": R.choice([5, 6, 7]),
                                    "username": "lumina_demo_ch", "date": 1794000000}
                    if R.random() < 0.5:
                        m["autoForward"] = True
                if focused:
                    kind = R.random()
                    m.pop("entities", None)
                    m.pop("buttons", None)
                    if kind < 0.35:
                        m["text"] = R.choice(["", "", "今天的照片", R.choice(templates)[:20], frag_cjk()])
                        m["media"] = {"kind": "photo", "id": R.choice(["100", "200", "300"])}
                        m.pop("forward", None)
                    elif kind < 0.6:
                        m["forward"] = R.choice([{"fromKind": "channel", "fromId": -1003000000003, "postId": R.choice([5, 6]), "date": 1794000000},
                                                 {"fromKind": "user", "fromId": 4242, "date": 1794000000}])
                        m["text"] = R.choice(["", R.choice(templates)])
                    else:
                        m["text"] = R.choice(pure)
                        m.pop("media", None)
                        m.pop("forward", None)
                        if R.random() < 0.2:
                            m["replyTo"] = 1
                            m["text"] = R.choice(["收到，謝謝老師！", "好的了解", m["text"]])
                if "media" in m and R.random() < 0.6 and m["media"]["kind"] == "photo":
                    m["media"]["id"] = R.choice(["100", "200"])
                for f in ("service", "sponsored", "scheduled"):
                    if R.random() < 0.02:
                        m[f] = True
                ev = {"op": "observe", "message": m}
                if R.random() < 0.2:
                    ev["now"] = date + R.choice([0, 3600, 2 * 86400, 9 * 86400])
                now = ev.get("now", max(now, m["date"]))
                chat.observe(m, ctx, now)
                if m["id"] not in seen:
                    seen.append(m["id"])
            elif k < 0.79:
                ids = R.sample(seen, min(len(seen), R.randint(1, 2))) + ([999] if R.random() < 0.2 else [])
                ev = {"op": "delete", "ids": ids}
                now = ev.get("now", now)
                chat.delete(ids, now)
            elif k < 0.84:
                ev = {"op": "notAd", "id": R.choice(seen + [999])}
                chat.mark_not_ad(ev["id"], ctx, now)
            elif k < 0.88:
                nd = dict(ctxd)
                nd["adminsKnown"] = True
                nd["memberHandles"] = list(ctxd["memberHandles"]) + R.choice([["deal_x88"], ["user_1", "user_2"], []])
                ev = {"op": "context", "context": nd}
                ctx = A.ChatContext.from_json(nd)
            else:
                ev = {"op": "expect"}
                if R.random() < 0.3:
                    ev["now"] = now + R.choice([0, 86400, 7 * 86400, 9 * 86400, 100 * 86400])
                now = ev.get("now", now)
                fold, states, decisions = {}, {}, {}
                for sens in A.SENSITIVITIES:
                    st = dict(settings)
                    st["sensitivity"] = sens
                    ds = {i: chat.decide(i, ctx, st, now) for i in seen}
                    fold[sens] = sorted(i for i, d in ds.items() if d["fold"])
                    states[sens] = {str(i): d["state"] for i, d in ds.items()}
                    decisions[sens] = {str(i): decision_tuple(d) for i, d in ds.items()}
                ev["fold"] = fold
                ev["states"] = states
                ev["decisions"] = decisions
            events.append(ev)
        scenarios.append({"id": "FZ-%d" % si, "category": "fuzz", "title": "fuzz", "note": "", "context": ctxd,
                          "settings": settings, "events": events, "blobHex": chat.serialize().hex(),
                          "version": chat.version})
    with open(os.path.join(OUT, "fuzz_scenarios.json"), "w", encoding="utf-8") as f:
        json.dump({"note": "fuzz", "baseTime": base, "scenarios": scenarios}, f, ensure_ascii=False)


gen_fingerprints()
gen_scenarios()
print("ok")
