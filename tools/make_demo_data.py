#!/usr/bin/env python3
"""Writes the demo answers of the relay API to ios/XRelayClient/Resources/Demo/demo_<name>.json.

The answers have the exact shape of docs/api-v2.md: every key the contract lists is present (null where it is
nullable). Accounts and posts are invented and written in Japanese. Images use the demo:// scheme (see
docs/ios-design.md §4.5). Times are stored relative to BASE_EPOCH under "_base"; DemoData moves created_at and
time to the present when it loads a file.

usage: python3 tools/make_demo_data.py
"""

import glob
import json
import os

BASE_EPOCH = 1794823500  # 2026-11-16 19:05 in Japan, when this file was written
DAY = 86400
OUT_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "ios", "XRelayClient", "Resources", "Demo")

BASIC_USER_KEYS = [
    "id", "name", "handle", "avatar", "verified", "square", "protected",
    "following", "followed_by", "blocking", "muting", "label",
]


# ---- text with entities -------------------------------------------------------

def utf16_len(text):
    """Entity offsets are UTF-16 code units (api-v2.md §2)."""
    return len(text.encode("utf-16-le")) // 2


class Rich:
    """A text and its entities, built together so that the offsets always match the text."""

    def __init__(self):
        self.text = ""
        self.entities = []

    def add(self, text):
        self.text += text
        return self

    def _entity(self, visible, kind, value):
        start = utf16_len(self.text)
        self.text += visible
        self.entities.append({"s": start, "e": start + utf16_len(visible), "k": kind, "v": value})
        return self

    def mention(self, handle):
        return self._entity("@" + handle, "mention", handle)

    def hashtag(self, tag):
        return self._entity("#" + tag, "hashtag", tag)

    def cashtag(self, symbol):
        return self._entity("$" + symbol, "cashtag", symbol)

    def url(self, display, full):
        return self._entity(display, "url", full)


def rich(text):
    return Rich().add(text)


def name_bold(name):
    """The name at the start of a notification text, in bold."""
    return [[0, utf16_len(name)]]


# ---- users --------------------------------------------------------------------

def make_label(text, badge_no):
    return {"text": text, "badge": "demo://avatar/" + badge_no}


def basic_user(uid, name, handle, *, verified=None, square=False, protected=False,
               following=False, followed_by=False, label=None):
    return {
        "id": uid,
        "name": name,
        "handle": handle,
        "avatar": "demo://avatar/" + uid,
        "verified": verified,
        "square": square,
        "protected": protected,
        "following": following,
        "followed_by": followed_by,
        "blocking": False,
        "muting": False,
        "label": label,
    }


def full_user(uid, name, handle, *, bio="", location="", link=None, joined=None, followers=0,
              friends=0, tweets=0, media_count=0, likes_count=0, pinned=(), **flags):
    user = basic_user(uid, name, handle, **flags)
    text = rich(bio) if isinstance(bio, str) else bio
    user.update({
        "banner": "demo://banner/" + uid,
        "bio": text.text,
        "bio_entities": text.entities,
        "location": location,
        "url": {"display": link[0], "expanded": link[1]} if link else None,
        "joined": joined,
        "followers": followers,
        "friends": friends,
        "tweets": tweets,
        "media_count": media_count,
        "likes_count": likes_count,
        "pinned_ids": list(pinned),
        "blocked_by": False,
        "follow_request_sent": False,
    })
    return user


def as_basic(user):
    """The user object inside a post: only the basic keys of api-v2.md §2.1."""
    return {key: user[key] for key in BASIC_USER_KEYS}


# ---- media, cards and polls ---------------------------------------------------

def photo(number, width, height, alt=None):
    return {"type": "photo", "url": "demo://photo/%d?w=%d&h=%d" % (number, width, height),
            "w": width, "h": height, "alt": alt, "video": None}


def video(number, width, height, duration_ms, alt=None):
    return {"type": "video", "url": "demo://photo/%d?w=%d&h=%d" % (number, width, height),
            "w": width, "h": height, "alt": alt,
            "video": {"mp4": "demo://video/%d.mp4" % number, "hls": None,
                      "duration_ms": duration_ms, "aspect": [width, height]}}


def gif(number, width, height, alt=None):
    return {"type": "gif", "url": "demo://photo/%d?w=%d&h=%d" % (number, width, height),
            "w": width, "h": height, "alt": alt,
            "video": {"mp4": "demo://video/%d.mp4" % number, "hls": None,
                      "duration_ms": 3_200, "aspect": [width, height]}}


def card_image(number, width, height):
    return {"url": "demo://card/%d" % number, "w": width, "h": height}


def card(kind, url, domain, title, description, image=None, poll=None):
    return {"type": kind, "url": url, "domain": domain, "title": title, "description": description,
            "image": image, "poll": poll}


def poll_of(choices, ends_at, final=False):
    return {
        "choices": [{"label": label, "count": count} for label, count in choices],
        "total": sum(count for _, count in choices),
        "ends_at": ends_at,
        "final": final,
    }


# ---- posts --------------------------------------------------------------------

_post_numbers = [0]


def new_id():
    """Post ids are 19-digit strings, numbered in creation order so that the output is the same on every run."""
    _post_numbers[0] += 1
    return "2122%015d" % _post_numbers[0]


def post(author, *, text="", rich_text=None, tid=None, ago=0, long=False, replies=0, reposts=0,
         likes=0, quotes=0, bookmarks=0, views=None, liked=False, retweeted=False, bookmarked=False,
         media=None, quote=None, quote_unavailable=None, card_=None, reply_to=None, conversation=None,
         lang="ja", sensitive=False, source=None, edited=False, place=None, reply_limited=False):
    """One post (api-v2.md §2.5). `ago` is the age in seconds at BASE_EPOCH."""
    content = rich_text if rich_text is not None else rich(text)
    post_id = tid or new_id()
    return {
        "id": post_id,
        "user": author,
        "text": content.text,
        "entities": content.entities,
        "long": long,
        "created_at": BASE_EPOCH - ago,
        "reply_count": replies,
        "retweet_count": reposts,
        "like_count": likes,
        "quote_count": quotes,
        "bookmark_count": bookmarks,
        "view_count": views,
        "liked": liked,
        "retweeted": retweeted,
        "bookmarked": bookmarked,
        "media": media or [],
        "quote": quote,
        "quote_unavailable": quote_unavailable,
        "card": card_,
        "reply_to": reply_to,
        "conversation_id": conversation or post_id,
        "retweeted_by": None,
        "retweet_id": None,
        "lang": lang,
        "sensitive": sensitive,
        "source": source,
        "edited": edited,
        "place": place,
        "reply_limited": reply_limited,
    }


def reply_to(parent, *handles):
    return {"id": parent["id"], "handles": list(handles)}


# ---- timeline items (api-v2.md §2.6 to §2.8) ----------------------------------

def tweet_item(tweet, *, context=None, above=False, below=False, focal=False):
    return {"t": "tweet", "tweet": tweet, "context": context,
            "above": above, "below": below, "focal": focal}


def more_item(cursor, label):
    return {"t": "more", "cursor": cursor, "label": label}


def header_item(text):
    return {"t": "header", "text": text}


def tombstone_item(text="このポストは削除されました。", *, above=False, below=False):
    return {"t": "tombstone", "text": text, "above": above, "below": below}


def user_item(user):
    return {"t": "user", "user": user}


def notification_item(entry_id, icon, text, bold, users, tweet, *, ago, url=None):
    return {"t": "notification", "id": entry_id, "icon": icon, "text": text, "bold": bold,
            "users": users, "tweet": tweet, "time": BASE_EPOCH - ago, "url": url}


def trend_item(name, *, context=None, meta=None, query=None, rank=None):
    return {"t": "trend", "name": name, "context": context, "meta": meta,
            "query": query or name, "rank": rank}


def page(items, *, top=None, bottom=None):
    """A list answer: items with the cursors (api-v2.md §2.6)."""
    return {"_base": BASE_EPOCH, "items": items, "top": top, "bottom": bottom}


# ---- the cast: invented accounts ----------------------------------------------

ME_PINNED_ID = None  # set below, once the pinned post exists

CAST = {
    "me": full_user("100001", "山田 太郎", "yamada_demo",
                    bio=rich("週末は写真、平日はコードを書いています。").add(" 写真の先生は ")
                    .mention("hanako_sato_demo").add(" さんです。 ").hashtag("写真部"),
                    location="東京", link=("example.com/yamada", "https://example.com/yamada"),
                    joined=1652972380, followers=1234, friends=321, tweets=4567, media_count=210,
                    likes_count=890),
    "hanako": full_user("100002", "佐藤 花子", "hanako_sato_demo", verified="blue",
                        following=True, followed_by=True,
                        bio="絵と写真を投稿しています。お仕事のご依頼はDMでお願いします（デモ）。",
                        location="神奈川県", joined=1560000000, followers=8393, friends=512,
                        tweets=2310, media_count=1480, likes_count=6120),
    "kenta": full_user("100003", "鈴木 健太", "kenta_suzuki", following=True,
                       bio="登山と天体観測。", location="埼玉県", joined=1600000000,
                       followers=212, friends=340, tweets=980, media_count=75, likes_count=410),
    "misaki": full_user("100004", "高橋 みさき", "misaki_takahashi", verified="business", square=True,
                        following=True, label=make_label("サンプル株式会社", "900"),
                        bio="架空の会社の広報担当です。", location="大阪府", joined=1500000000,
                        followers=15230, friends=180, tweets=5600, media_count=640, likes_count=3300),
    "sakura": full_user("100005", "伊藤 さくら", "sakura_ito_demo", verified="government",
                        bio="デモ用の行政アカウントです。", location="", joined=1420000000,
                        followers=40120, friends=12, tweets=880, media_count=20, likes_count=50),
    "osamu": full_user("100006", "渡辺 修", "osamu_watanabe", protected=True, followed_by=True,
                       bio="鍵付きのアカウントです。", location="京都府", joined=1620000000,
                       followers=77, friends=95, tweets=310, media_count=12, likes_count=140),
    "aoi": full_user("100007", "中村 葵", "aoi_nakamura", following=True, followed_by=True,
                     bio="カフェ巡りとスイーツ🍰", location="東京都", joined=1580000000,
                     followers=3050, friends=610, tweets=7420, media_count=1100, likes_count=9870),
    "sho": full_user("100008", "小林 翔", "sho_kobayashi", following=True,
                     bio="長い文章を書くのが好きです。", location="福岡県", joined=1540000000,
                     followers=432, friends=201, tweets=2990, media_count=60, likes_count=1230),
    "yui": full_user("100009", "加藤 ゆい", "yui_kato_art", following=True, followed_by=True,
                     bio="水彩画を描いています。", location="東京都", joined=1550000000,
                     followers=5120, friends=260, tweets=1870, media_count=940, likes_count=2750),
    "takuma": full_user("100010", "木村 拓真", "takuma_kimura", followed_by=True,
                        bio="ゲームと散歩。", location="千葉県", joined=1610000000,
                        followers=98, friends=150, tweets=3400, media_count=21, likes_count=560),
    "yuis": full_user("100011", "清水 結衣", "yui_shimizu",
                      bio="引用リポストが多めです。", location="", joined=1590000000,
                      followers=640, friends=420, tweets=5210, media_count=130, likes_count=2040),
    "kaito": full_user("100012", "井上 海斗", "kaito_inoue", following=True,
                       bio="英語の投稿も少しします。", location="Tokyo", joined=1570000000,
                       followers=301, friends=290, tweets=1560, media_count=44, likes_count=880),
    "news": full_user("100013", "デモ新聞", "demo_news_daily", verified="business",
                      bio="架空の新聞社のデモアカウントです。", location="", joined=1450000000,
                      followers=250000, friends=40, tweets=18000, media_count=3100, likes_count=120),
    "memo": full_user("100014", "技術メモ", "tech_memo_demo",
                      bio="小さなツールを公開しています。", location="", joined=1530000000,
                      followers=1800, friends=30, tweets=640, media_count=12, likes_count=300),
    "video": full_user("100015", "動画紹介", "video_intro_demo",
                       bio="紹介動画のデモです。", location="", joined=1480000000,
                       followers=9800, friends=5, tweets=1200, media_count=300, likes_count=40),
    "poll": full_user("100016", "アンケート係", "poll_keeper_demo",
                      bio="週末のアンケートを出しています。", location="", joined=1520000000,
                      followers=760, friends=60, tweets=900, media_count=5, likes_count=20),
}
BASIC = {key: as_basic(user) for key, user in CAST.items()}

# ---- posts that several answers share (each post is created once, so it has the same content in every file) ----

p_hello = post(BASIC["aoi"], text="おはようございます。今日も一日がんばりましょう！",
               ago=180, likes=12, replies=1, reposts=2, views=3450)
p_sunset = post(BASIC["hanako"], text="夕焼けがきれいでした。", media=[photo(101, 1200, 800, "夕焼けの空と海")],
                ago=1020, likes=88, replies=3, reposts=6, views=12034, place="神奈川県 逗子市",
                source="Twitter for Android")
p_cafe = post(BASIC["aoi"], text="新しいカフェに行ってきました 🍰",
              media=[photo(102, 1200, 900, "ケーキと紅茶"), photo(103, 900, 1200, "店内")],
              ago=2400, likes=40, replies=2, reposts=1, views=5120, place="東京 世田谷区")
p_hike = post(BASIC["kenta"], text="週末の登山。展望台から見た景色です。",
              media=[photo(104, 1200, 800), photo(105, 800, 1200), photo(106, 1200, 800)],
              ago=3900, likes=57, replies=4, reposts=3, views=7840)
p_art = post(BASIC["yui"], text="新作まとめです。",
             media=[photo(107, 800, 800), photo(108, 800, 800), photo(109, 800, 800), photo(110, 800, 800)],
             ago=7200, likes=233, replies=9, reposts=21, views=20110)
p_tall = post(BASIC["misaki"], text="縦長の写真です。", media=[photo(111, 1080, 1920, "縦長の写真")],
              ago=10800, likes=19, reposts=1, views=1980)
p_panorama = post(BASIC["hanako"], text="パノラマ写真です。", media=[photo(112, 1600, 900)],
                  ago=18000, likes=143, replies=7, reposts=12, views=28750)
p_video = post(BASIC["yui"], text="制作の様子（動画）", media=[video(113, 1280, 720, 35134, "制作中の動画")],
               ago=21600, likes=512, replies=15, reposts=44, views=190233)
p_gif = post(BASIC["aoi"], text="GIFで反応してみました。", media=[gif(114, 480, 480)],
             ago=25200, likes=77, replies=2, reposts=5, views=6600)
p_quote_media = post(BASIC["yuis"], text="この夕焼け、すごく好きです。", quote=p_sunset,
                     ago=28800, likes=31, replies=1, reposts=2, views=4100)
p_quote_text = post(BASIC["kaito"], text="朝からいい言葉ですね。", quote=p_hello,
                    ago=32400, likes=9, views=880)
p_quote_gone = post(BASIC["takuma"], text="この投稿は引用できませんでした。",
                    quote_unavailable="このポストは表示できません。", ago=36000, likes=3, views=410)
p_news = post(BASIC["news"], text="新しい記事を公開しました。", ago=39600,
              likes=260, replies=12, reposts=88, views=54000,
              card_=card("summary_large_image", "https://example.com/news/2026/11/demo-article", "example.com",
                         "週末の天気と気温の変化（デモ記事）",
                         "週末は全国的に晴れる見込みです。朝晩は冷え込むため、防寒具があると安心です。",
                         image=card_image(201, 800, 419)))
p_tech = post(BASIC["memo"], text="新しい記録を追加しました。", ago=43200,
              likes=18, replies=2, reposts=4, views=2300,
              card_=card("summary", "https://example.org/memo/demo-tool", "example.org",
                         "デモ用の小さなツールを公開", "ローカルで動く小さな変換ツールです。",
                         image=card_image(202, 240, 240)))
p_player = post(BASIC["video"], text="新しい動画です。", ago=46800,
                likes=95, replies=3, reposts=10, views=30100,
                card_=card("player", "https://example.com/video/demo-42", "example.com",
                           "デモ動画 第42話", "約3分の紹介動画です。", image=card_image(203, 800, 450)))
p_poll = post(BASIC["poll"], text="今週末どこに行きたいですか？", ago=50400,
              likes=40, replies=6, reposts=8, views=8800,
              card_=card("poll", "", "", "", "",
                         poll=poll_of([("山", 128), ("海", 96), ("街", 41)], BASE_EPOCH + 2 * DAY)))
p_repost_original = post(BASIC["hanako"], text="写真展の準備が終わりました。",
                         media=[photo(115, 1200, 800, "展示室")],
                         ago=61200, likes=210, replies=11, reposts=35, views=40210)
p_repost = dict(p_repost_original, retweeted_by=BASIC["kaito"], retweet_id=new_id())
p_long = post(BASIC["sho"], long=True, ago=64800, likes=130, replies=8, reposts=14, views=22400,
              rich_text=rich("毎週日曜日の朝、近所の公園で写真の撮り方を教えるサークルを開いています。"
                             "初心者の方も大歓迎です。カメラは何でもかまいません。"
                             "スマートフォンでも十分に楽しめます。"
                             "先月は十人ほどが集まり、光の向きや構図について話し合いました。"
                             "次回は紅葉の季節に合わせて、池の周りを歩く予定です。"
                             "参加費は無料で、飲み物を持ち寄る形で行っています。"
                             "詳しくはこちら ").url("example.com/circle…", "https://example.com/circle/schedule"))
p_emoji_tag = post(BASIC["aoi"], ago=72000, likes=21, replies=2, reposts=1, views=2900,
                   rich_text=rich("今日の夕ご飯は ").hashtag("週末").add(" のごちそうです 🎉 ")
                   .mention("yamada_demo").add(" も来ませんか？"))
p_reply = post(BASIC["takuma"], text="ありがとうございます！", ago=79200, likes=4, views=300,
               reply_to=reply_to(p_sunset, "hanako_sato_demo"), conversation=p_sunset["id"])
p_ctx = post(BASIC["hanako"], text="週末の撮影会の参加者を募集しています。", ago=86400,
             likes=25, replies=2, reposts=6, views=9000)
p_quiet = post(BASIC["kenta"], text="ひさしぶりに投稿します。", ago=129600)  # no counts, no view counter
p_english = post(BASIC["kaito"], text="Good morning from Tokyo! The sky is clear today.", lang="en",
                 ago=140000, likes=2, views=150)
p_viral = post(BASIC["misaki"], ago=150000, likes=1234567, replies=4567, reposts=123456, quotes=890,
               bookmarks=12345, views=345678901, edited=True, source="Twitter for Android",
               rich_text=rich("新商品の発表です。 ").cashtag("SAMPLE").add(" は架空の記号です。"))
p_edited = post(BASIC["sho"], text="誤字を直しました。", ago=158400, likes=3, edited=True)
p_follow = post(BASIC["osamu"], text="今日は雨ですね。写真の整理をしています。", ago=300, likes=1, views=90)

# ---- the home timeline ----

HOME_FORYOU = page([
    tweet_item(p_hello), tweet_item(p_sunset), tweet_item(p_cafe), tweet_item(p_hike), tweet_item(p_art),
    tweet_item(p_tall), tweet_item(p_panorama), tweet_item(p_video), tweet_item(p_gif),
    tweet_item(p_quote_media), tweet_item(p_quote_text), tweet_item(p_quote_gone),
    tweet_item(p_news), tweet_item(p_tech), tweet_item(p_player), tweet_item(p_poll),
    tweet_item(p_repost), tweet_item(p_long), tweet_item(p_emoji_tag), tweet_item(p_reply),
    tweet_item(p_ctx, context={"k": "text", "text": "あなたへのおすすめ"}),
    tombstone_item(),
    tweet_item(p_quiet), tweet_item(p_english), tweet_item(p_viral), tweet_item(p_edited),
], bottom="home-fy-2")

HOME_FOLLOWING = page([
    tweet_item(p_follow), tweet_item(p_panorama), tweet_item(p_hike), tweet_item(p_long),
    tweet_item(p_tech), tweet_item(p_quote_text), tweet_item(p_edited), tweet_item(p_english),
], bottom="home-fo-2")

OLDER = [
    ("hanako", "梅雨明けが待ち遠しいです。"), ("kenta", "新しいノートを買いました。"),
    ("aoi", "週末の映画がよかったです。"), ("sho", "長い一日でした。おやすみなさい。"),
    ("yui", "ペン先を変えたら線が変わりました。"), ("takuma", "新しいゲームを始めました。"),
    ("kaito", "晴れた日の散歩が気持ちいいです。"), ("yuis", "コーヒーの淹れ方を変えてみました。"),
    ("misaki", "今月の数字をまとめました。"), ("osamu", "雨の日は読書がはかどります。"),
]
HOME_PAGE2 = page([
    tweet_item(post(BASIC[key], text=text, ago=190000 + index * 6100, likes=index * 7,
                    replies=index % 3, reposts=index, views=1000 + index * 321))
    for index, (key, text) in enumerate(OLDER)
])

# ---- the post detail: two ancestors, the focal post, three reply threads, more, header, related posts ----

ANCESTOR_1 = post(BASIC["kenta"], text="新しい水彩画の作品が見たいです。", ago=5 * 3600, likes=6, views=900)
ANCESTOR_2 = post(BASIC["hanako"], text="楽しみにしています！", ago=2 * 3600, likes=9, views=1400,
                  reply_to=reply_to(ANCESTOR_1, "kenta_suzuki"), conversation=ANCESTOR_1["id"])
FOCAL = post(BASIC["yui"], text="アトリエで描いた水彩画です。", media=[photo(301, 1200, 900, "水彩画")],
             ago=1800, replies=4, reposts=112, likes=1272, quotes=8, bookmarks=215, views=134034,
             reply_to=reply_to(ANCESTOR_2, "hanako_sato_demo", "kenta_suzuki"), conversation=ANCESTOR_1["id"])
THREAD_1 = post(BASIC["aoi"], text="素敵です！", ago=900, likes=5, views=410,
                reply_to=reply_to(FOCAL, "yui_kato_art"), conversation=ANCESTOR_1["id"])
THREAD_2 = post(BASIC["kenta"], text="色使いが好きです。", ago=700, likes=3, views=300,
                reply_to=reply_to(FOCAL, "yui_kato_art"), conversation=ANCESTOR_1["id"])
THREAD_3_QUESTION = post(BASIC["sho"], text="この色、どこの絵具ですか？", ago=600, likes=2, views=260,
                         reply_to=reply_to(FOCAL, "yui_kato_art"), conversation=ANCESTOR_1["id"])
THREAD_3_ANSWER = post(BASIC["yui"], text="水彩絵具のセットです。", ago=400, likes=7, views=520,
                       reply_to=reply_to(THREAD_3_QUESTION, "sho_kobayashi"), conversation=ANCESTOR_1["id"])
TWEET_DEFAULT = page([
    tweet_item(ANCESTOR_1, below=True),
    tweet_item(ANCESTOR_2, above=True, below=True),
    tweet_item(FOCAL, above=True, focal=True),
    tweet_item(THREAD_1),
    tweet_item(THREAD_2),
    tweet_item(THREAD_3_QUESTION, below=True),
    tweet_item(THREAD_3_ANSWER, above=True),
    more_item("tweet-replies-2", "返信をさらに表示"),
    header_item("もっと見つける"),
    tweet_item(p_sunset),
    tweet_item(p_hike),
], bottom="tweet-replies-2")

# ---- search ----

s1 = post(BASIC["aoi"], text="うちの猫が窓辺で日向ぼっこしています。", media=[photo(401, 1200, 800, "窓辺の猫")],
          ago=4000, likes=120, replies=5, reposts=9, views=12000)
s2 = post(BASIC["hanako"], text="猫の写真をまとめました。", media=[photo(402, 800, 800), photo(403, 800, 800)],
          ago=9000, likes=310, replies=12, reposts=40, views=56000)
s3 = post(BASIC["kenta"], text="猫じゃらしで遊ぶ猫は最強です。", ago=15000, likes=44, replies=1, reposts=2, views=3300)
s4 = post(BASIC["takuma"], text="猫カフェに行ってきました。", ago=30000, likes=18, views=2100, sensitive=True)
s5 = post(BASIC["yui"], text="猫の水彩画を描きました。", media=[photo(404, 900, 900, "猫の水彩画")],
          ago=60000, likes=520, replies=8, reposts=33, views=80400)
s6 = post(BASIC["sho"], text="猫の名前を考えるのが難しいです。", ago=90000, likes=7, views=600, reply_limited=True)
SEARCH_TOP = page([tweet_item(x) for x in [s2, s5, s1, s3, s4, s6]])
SEARCH_LATEST = page([tweet_item(x) for x in [s1, s2, s3, s4, s5, s6]])
SEARCH_MEDIA = page([tweet_item(x) for x in [p_cafe, p_hike, p_art, p_panorama, p_video, p_gif, p_sunset, s1, s2, s5]])
SEARCH_PEOPLE = page([user_item(CAST[key]) for key in ["hanako", "osamu", "sakura", "misaki", "takuma", "yuis"]])

# ---- the logged-in account (yamada_demo) ----

p_pinned = post(BASIC["me"], text="はじめまして。写真とコードの記録を残していきます。",
                ago=2592000, likes=54, replies=3, reposts=5, views=9100)
CAST["me"]["pinned_ids"] = [p_pinned["id"]]
m1 = post(BASIC["me"], text="今日の散歩道で撮った一枚です。", media=[photo(116, 1200, 800, "散歩道")],
          ago=5400, likes=34, replies=2, reposts=3, views=2600)
m2 = post(BASIC["me"], text="コードの整理をしました。", ago=12600, likes=15, views=1400)
m3 = post(BASIC["me"], text="夕方の空。", media=[photo(117, 1200, 900), photo(118, 900, 1200)],
          ago=36000, likes=61, replies=3, reposts=4, views=5300)
m4 = post(BASIC["me"], text="新しいレンズを試しました。", media=[photo(119, 1200, 800)],
          ago=90000, likes=44, replies=1, views=4100)
m5 = post(BASIC["me"], ago=170000, likes=9, views=800, rich_text=rich("週末のメモです。 ").hashtag("写真部"))
m6 = post(BASIC["me"], text="ありがとうございました。", ago=260000, likes=6, views=500)
r1 = post(BASIC["me"], text="ぜひ行ってみてください！", ago=20000, likes=2, views=190,
          reply_to=reply_to(p_sunset, "hanako_sato_demo"), conversation=p_sunset["id"])
r2 = post(BASIC["me"], text="いいですね、次の撮影会も参加したいです。", ago=110000, likes=3, views=240,
          reply_to=reply_to(p_ctx, "hanako_sato_demo"), conversation=p_ctx["id"])
r3 = post(BASIC["me"], text="おいしそうです。", ago=200000, likes=1, views=110,
          reply_to=reply_to(p_cafe, "aoi_nakamura"), conversation=p_cafe["id"])
l1 = post(BASIC["hanako"], text="撮影の光が好きです。", media=[photo(120, 1200, 800)],
          ago=40000, likes=311, replies=5, reposts=9, views=18000, liked=True)
l2 = post(BASIC["kenta"], text="夜の山頂で見た星。", media=[photo(121, 1200, 900)],
          ago=50000, likes=190, replies=2, reposts=6, views=14000, liked=True)
l3 = post(BASIC["aoi"], text="新作のスイーツは甘さ控えめです。", ago=99000, likes=88, views=5400, liked=True)
l4 = post(BASIC["sho"], text="本の感想を書きました。", ago=120000, likes=60, views=3600, liked=True)
USER_TIMELINE_POSTS = page([
    tweet_item(p_pinned, context={"k": "pin", "text": "固定"}),
    tweet_item(m1), tweet_item(m2), tweet_item(m3), tweet_item(m4), tweet_item(m5), tweet_item(m6),
], bottom="posts-2")
USER_TIMELINE_REPLIES = page([tweet_item(r1), tweet_item(r2), tweet_item(r3)])
USER_TIMELINE_MEDIA = page([tweet_item(m1), tweet_item(m3), tweet_item(m4)])
USER_TIMELINE_LIKES = page([tweet_item(l1), tweet_item(l2), tweet_item(l3), tweet_item(l4)])
USER_FOLLOWS = page([user_item(CAST[key]) for key in ["hanako", "kenta", "misaki", "aoi", "sho", "yui", "kaito"]])

# ---- notifications and bookmarks ----

mention1 = post(BASIC["sho"], text="写真見ました！", ago=700, likes=2, views=150,
                reply_to=reply_to(m1, "yamada_demo"), conversation=m1["id"])
mention2 = post(BASIC["takuma"], text="次の週末は空いていますか？", ago=3000, views=90,
                reply_to=reply_to(m2, "yamada_demo"), conversation=m2["id"])
mention3 = post(BASIC["aoi"], text="一緒に行きましょう！", ago=4200, likes=6, views=330,
                reply_to=reply_to(p_emoji_tag, "yamada_demo"), conversation=p_emoji_tag["id"])
mention4 = post(BASIC["kenta"], text="写真の構図の話を聞きたいです。", ago=9000, likes=1, views=77,
                reply_to=reply_to(m3, "yamada_demo"), conversation=m3["id"])


def named(key):
    return CAST[key]["name"]


NOTIFICATIONS_ALL = page([
    notification_item("ntf-001", "heart", named("hanako") + "さんがあなたのポストにいいねしました",
                      name_bold(named("hanako")), [BASIC["hanako"]], m1, ago=600,
                      url="https://x.com/yamada_demo/status/" + m1["id"]),
    notification_item("ntf-002", "repost", named("kenta") + "さんがあなたのポストをリポストしました",
                      name_bold(named("kenta")), [BASIC["kenta"]], m3, ago=3600),
    notification_item("ntf-003", "person", named("misaki") + "さんにフォローされました",
                      name_bold(named("misaki")), [BASIC["misaki"]], None, ago=7200),
    notification_item("ntf-004", "star", named("yui") + "さんのポストが注目されています",
                      name_bold(named("yui")), [BASIC["yui"]], m4, ago=10800),
    notification_item("ntf-005", "bell", "お知らせ: 新しいバージョンがあります", [], [], None, ago=14400),
    notification_item("ntf-006", "reply", named("takuma") + "さんがあなたのポストに返信しました",
                      name_bold(named("takuma")), [BASIC["takuma"]], mention2, ago=18000),
    notification_item("ntf-007", "logo", "X からのお知らせ（デモ）", [], [], None, ago=21600),
    notification_item("ntf-008", "alert", "アカウントの確認が必要です（デモ）", [], [], None, ago=25200),
    notification_item("ntf-009", "sparkle", "新しいフォロワーが増えました（デモ）", [], [], None, ago=28800),
    notification_item("ntf-010", "heart", named("hanako") + "さんほか7人がいいねしました",
                      name_bold(named("hanako")),
                      [BASIC[key] for key in ["hanako", "kenta", "aoi", "sho", "yui", "takuma", "kaito", "misaki"]],
                      m1, ago=32400),
    tweet_item(mention1),
    tweet_item(mention3),
])
NOTIFICATIONS_MENTIONS = page([tweet_item(x) for x in [mention1, mention2, mention3, mention4]])

bm1 = post(BASIC["hanako"], text="撮影のコツをまとめました。", media=[photo(122, 1200, 800)],
           ago=170000, likes=90, bookmarks=40, bookmarked=True, views=7000)
bm2 = post(BASIC["aoi"], text="この店のケーキは本当においしいです。", ago=200000, likes=50, bookmarks=9,
           bookmarked=True, views=2400)
bm3 = post(BASIC["memo"], text="便利なツールのまとめ。", ago=250000, likes=33, bookmarked=True, views=1500)
bm4 = post(BASIC["yui"], text="水彩紙の選び方について。", media=[photo(123, 1000, 1000)],
           ago=300000, likes=120, bookmarks=22, bookmarked=True, views=8200)
bm5 = post(BASIC["kaito"], text="英語の勉強法をまとめました。", ago=400000, likes=12, bookmarked=True, views=900)
BOOKMARKS = page([tweet_item(x) for x in [bm1, bm2, bm3, bm4, bm5]])

# ---- explore ----

EXPLORE = {
    "_base": BASE_EPOCH,
    "tabs": [
        {"id": "for_you", "label": "話題を検索"},
        {"id": "trending", "label": "トレンド"},
        {"id": "news", "label": "ニュース"},
        {"id": "sports", "label": "スポーツ"},
    ],
    "tab": "for_you",
    "items": [
        trend_item("デモフェス", context="エンターテインメント · トレンド", meta="1.2万件のポスト", rank=1),
        trend_item("週末の天気", context="天気 · トレンド", meta="3,456件のポスト", rank=2),
        trend_item("新作ゲーム発表（デモ）", context="ゲーム · トレンド", meta="8.9万件のポスト", rank=3),
        trend_item("#夏の思い出", query="夏の思い出", context="話題", meta="45.6万件のポスト", rank=4),
        trend_item("デモ新聞の特集", context="ニュース", meta="1,234件のポスト", rank=5),
        trend_item("絵画コンテスト", meta="567件のポスト", rank=6),
        trend_item("サッカー（デモ）", context="スポーツ · トレンド", rank=7),
        trend_item("週末の撮影会"),
    ],
    "top": None,
    "bottom": None,
}


# ---- the files ----

def build_answers():
    """File name (without demo_ and .json) -> answer."""
    answers = {
        "me": {"_base": BASE_EPOCH, "user": CAST["me"], "badges": {"notifications": 5, "messages": 0}},
        "badges": {"_base": BASE_EPOCH, "notifications": 5, "messages": 0},
        "home_foryou": HOME_FORYOU,
        "home_following": HOME_FOLLOWING,
        "home_page2": HOME_PAGE2,
        "tweet_default": TWEET_DEFAULT,
        "search_top": SEARCH_TOP,
        "search_latest": SEARCH_LATEST,
        "search_people": SEARCH_PEOPLE,
        "search_media": SEARCH_MEDIA,
        "user_timeline_posts": USER_TIMELINE_POSTS,
        "user_timeline_replies": USER_TIMELINE_REPLIES,
        "user_timeline_media": USER_TIMELINE_MEDIA,
        "user_timeline_likes": USER_TIMELINE_LIKES,
        "user_follows": USER_FOLLOWS,
        "notifications_all": NOTIFICATIONS_ALL,
        "notifications_mentions": NOTIFICATIONS_MENTIONS,
        "bookmarks": BOOKMARKS,
        "explore": EXPLORE,
        "user_default": {"_base": BASE_EPOCH, "user": CAST["me"]},
    }
    for user in CAST.values():
        answers["user_" + user["handle"]] = {"_base": BASE_EPOCH, "user": user}
    return answers


def main():
    os.makedirs(OUT_DIR, exist_ok=True)
    for stale in glob.glob(os.path.join(OUT_DIR, "demo_*.json")):
        os.remove(stale)
    for name, answer in sorted(build_answers().items()):
        path = os.path.join(OUT_DIR, "demo_%s.json" % name)
        with open(path, "w", encoding="utf-8", newline="\n") as handle:
            json.dump(answer, handle, ensure_ascii=False, indent=2)
            handle.write("\n")
        items = len(answer["items"]) if "items" in answer else "-"
        print("demo_%s.json  items: %s" % (name, items))


if __name__ == "__main__":
    main()
