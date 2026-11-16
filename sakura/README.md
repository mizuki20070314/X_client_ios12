# さくらレンタルサーバー向け Python CGI

Chromiumや常駐プロセスを使わず、CGIの各リクエストからXの非公式Web APIへ直接HTTP通信します。XのログインCookieとクライアントキーは`~/private/xrelay/config.json`に保存し、`www`以下には置きません。`TwitterFrontendFlow`の自動ログインやログイン検知回避機能は使用しません。

## 機能と制限

- `/v2/` のJSON APIで、タイムライン（おすすめ・フォロー中）、ポストの詳細と返信、検索、ユーザー、ユーザーのタイムライン（ポスト・返信・メディア・いいね）、フォロー/フォロワー、通知、ブックマーク、話題（探索）を読めます。投稿・返信・削除、いいね・リポスト・ブックマーク、フォロー・ミュート・ブロックもできます。仕様は`docs/api-v2.md`を参照してください。
- 旧版のアプリ向けに`/i/api/graphql/...`も残しています（ホーム、検索、投稿のみ）。
- DM、メディアのアップロードは未対応です。
- Xの内部GraphQL APIは非公式で、仕様・認証・トランザクションIDが変更されると動かなくなる可能性があります。
- iOSアプリに保存するBearerキーはCGIへのアクセス用です。XのCookieやBearerはサーバーの非公開設定だけに保存します。
- Cookieを取得したブラウザーのUser-AgentとOS platformを設定してください。Xの認証Cookieは失効・無効化されることがあります。再ログインはブラウザー側で行い、CGI設定を更新してください。
- CGIはリクエストごとに終了します。ブラウザーworkerや50分ループは起動しません。
- Python 3.8で動くように書いています。テストはネットワークに接続せず、`requests`がなくても動きます。

## 構成

```text
sakura/
  README.md               このファイル
  requirements.txt        サーバーに入れる外部パッケージ
  setup_config.py         設定（Cookie、CGIキー）を対話で作成・更新する
  deploy.sh               サーバーでテスト、アプリの配置、www の転送、動作確認をする
  app/xrelay_app/         アプリ本体（deploy.sh で ~/private/xrelay/app/ へ配置）
    config.py             非公開設定、プロフィール、CGIキーの確認
    cgiio.py              リクエストの解析、レスポンス（gzip を含む）
    transaction.py        x-client-transaction-id の生成と認証素材のキャッシュ
    catalog.py            GraphQL の query id と feature の一覧
    xapi.py               Xへの呼び出しと、応答の判定
    routes.py             /v2 の各API
    legacy.py             旧版の /i/api/graphql 中継
    main.py               振り分けと認証、エラー応答
    data/ops.json         同梱の query id 一覧（最後の予備）
  www/                    ドキュメントルームへ置くファイル
    .htaccess
    requests.ndjson       旧版の一覧
    cgi-bin/xrelay.cgi    入口（アプリを探して実行するだけ）
  tools/update_ops.py     同梱の query id 一覧（data/ops.json）を作り直す
  tests/                  単体テスト（`python -m unittest discover -s sakura/tests -v`）
```

## セットアップ

1. 既存サイトを上書きしないよう、公開ディレクトリのサブフォルダー`/home/<アカウント>/www/xclient/`を作ります。スクリプトは`755`または`705`、ディレクトリは`755`または`705`にします。ファイルは次の「デプロイ」の手順で置きます。

2. Python 3.8と互換性のある依存関係をユーザー領域へ入れます。

   ```sh
   python -m pip install --target ~/private/xrelay/python -r ~/private/xclient_ios12/sakura/requirements.txt
   ```

   SakuraのPythonはOpenSSLが古い環境があるため、`urllib3`は1.26系に固定しています。`bs4`と`xclienttransaction`は認証素材を更新するときだけ使います。

3. `sakura/setup_config.py`をホームディレクトリなど`www`の外へ置き、SSHで対話実行します。公開APIカタログからWeb Appの既定ヘッダーを取得し、アカウントCookieは入力時に画面へ表示しません。

   ```sh
   python ~/private/xclient_ios12/sakura/setup_config.py
   ```

   Cookieの`auth_token`/`ct0`と、Cookie取得時のブラウザーUser-Agent/OSを対話入力します。必要ならX Web AppのBearer tokenを上書きできます。値は入力中に表示されず、設定ファイルは`600`、親ディレクトリは`700`で作成されます。表示されるCGIキーだけをiOSアプリの設定に入力してください。CookieやBearer tokenをチャットやGitHubへ貼らないでください。

4. iOSアプリには、`https://<公開ドメイン>/xclient`、プロフィール名（初期値`account1`）、CGIキーを設定し、接続テストを行います。SSHのホスト名（`<SSHホスト名>`）はWebサイトの公開URLとは限りません。

## デプロイ（初回と更新）

サーバーのリポジトリ（`~/private/xclient_ios12`）で次を実行します。

```sh
cd ~/private/xclient_ios12
git pull
sh sakura/deploy.sh                  # 既定の公開先 ~/www/xclient
sh sakura/deploy.sh <公開先のパス>    # 公開先を変える場合
```

`deploy.sh`は次の順に行い、途中で失敗したら止まります。

1. `app/`と`www/cgi-bin/xrelay.cgi`を`py_compile`する。
2. `sakura/tests`のテストを実行する。失敗したら何も入れ替えない。
3. `app/xrelay_app`を`~/private/xrelay/app/`へ入れ替える（新しい版を横に作ってから置き換えます）。
4. `.htaccess`、`requests.ndjson`、`cgi-bin/xrelay.cgi`（755）を公開先へコピーする。
5. `/healthz`で動作確認する。`{"status":"ok"}`が返らなければ失敗です。

設定（`config.json`）とキャッシュは更新しません。`requests.ndjson`やクエリIDが古くなった場合も、`git pull`と`deploy.sh`だけで直ります。

## キャッシュとファイルの場所

| 場所 | 中身 | 権限 | 扱い |
|------|------|------|------|
| `~/private/xrelay/config.json` | Cookie、Bearer、CGIキーのハッシュ | 600 | 秘密。`setup_config.py`で更新 |
| `~/private/xrelay/python/` | 外部パッケージ | - | `pip install --target`で入れる |
| `~/private/xrelay/app/xrelay_app/` | アプリ本体 | 700 | `deploy.sh`が置き換える |
| `~/private/xrelay/tid-cache/<指紋>/keys.json` | x-client-transaction-idの認証素材 | 600 | 6時間で更新。X が404を返すと作り直す |
| `~/private/xrelay/cache/ops.json` | query idの一覧（XのAPIカタログ） | 600 | 24時間で更新。失敗したら1時間は取りに行かない |
| `~/private/xrelay/cache/ops.failed` | 最後にカタログの取得に失敗した時刻 | 600 | 消してよい |

キャッシュは消しても問題ありません。次の要求で作り直されます。`XRELAY_HOME`を設定すると、この場所（`~/private/xrelay`）を変えられます。`XRELAY_CONFIG`を設定すると、設定ファイルの場所だけを変えられます。

## トラブルシューティング

- **アプリで「CGIキーが無効」（401）**: iOSアプリのCGIキーが違います。`setup_config.py --rotate-client-key`で発行し直すと、古いキーは使えなくなります。
- **403（`x_auth`、「Xのログイン情報が無効です」）**: Xの`auth_token`か`ct0`が失効しています。ブラウザーで再ログインし、`setup_config.py`でCookieとUser-Agentを入れ直してください。
- **503（`unavailable`）**: 次のどれかです。`config.json`がない、権限が600でない（`chmod 600`）、外部パッケージが入っていない（`pip install --target`をやり直す）、アプリが配置されていない（`deploy.sh`を実行する）。
- **502（「Xの認証素材を取得できませんでした。」）**: X のWeb アプリの構成が変わったか、サーバーからXへ接続できていません。`tid-cache`を消して再試行してください。直らなければ`sakura/app/xrelay_app/transaction.py`の`ONDEMAND_RE`とフォールバックの確認が必要です。
- **検索が404になる**: 旧版ではトランザクションIDが古いまま送られていました。新しい版では認証素材を取り直し、404のときは一度だけ作り直して送り直します。それでも直らないときは`deploy.sh`の再実行と、`tid-cache`の削除を試してください。
- **429（`rate_limited`）**: Xのレート制限です。`retry_after`秒の後に再試行してください。
- **`{"error": "CGI application is not installed."}`（503）**: `~/private/xrelay/app/xrelay_app`がありません。`deploy.sh`を実行してください。

動作確認は`/healthz`だけを使ってください。CGIキーをコマンドラインに書くと、シェルの履歴に残ります。

```sh
curl https://<公開ドメイン>/xclient/healthz
```

## 更新の流れ（Xの仕様変更に対して）

- query idが変わった: 公開のAPIカタログ（`API.json`）をダウンロードし、`python -I sakura/tools/update_ops.py <API.jsonのパス>`で`app/xrelay_app/data/ops.json`を作り直せます。引数を省くと、公開カタログを直接取りに行きます。
- サーバーは、キャッシュ（`cache/ops.json`）が24時間を過ぎたときだけ公開のAPIカタログを取り直します。取得に失敗したら`data/ops.json`を使います。通常は手作業が要りません。
