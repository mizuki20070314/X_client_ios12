# さくらレンタルサーバー向け Python CGI

Chromiumや常駐プロセスを使わず、CGIの各リクエストからXの非公式Web APIへ直接HTTP通信します。XのログインCookieとクライアントキーは`~/private/xrelay/config.json`に保存し、`www`以下には置きません。`TwitterFrontendFlow`の自動ログインやログイン検知回避機能は使用しません。

## 機能と制限

- ホームタイムライン、キーワード検索、テキスト投稿のみ許可します。
- Xの内部GraphQL APIは非公式で、仕様・認証・トランザクションIDが変更されると動かなくなる可能性があります。
- iOSアプリに保存するBearerキーはCGIへのアクセス用です。XのCookieやBearerはサーバーの非公開設定だけに保存します。
- Cookieを取得したブラウザーのUser-AgentとOS platformを設定してください。Xの認証Cookieは失効・無効化されることがあります。再ログインはブラウザー側で行い、CGI設定を更新してください。
- CGIはリクエストごとに終了します。ブラウザーworkerや50分ループは起動しません。

## セットアップ

1. 既存サイトを上書きしないよう、公開ディレクトリのサブフォルダー`/home/<アカウント>/www/xclient/`を作り、`sakura/www/`の中身（`.htaccess`、`requests.ndjson`、`cgi-bin/xrelay.cgi`）をそこへ転送します。スクリプトは`755`または`705`、ディレクトリは`755`または`705`にします。
2. Python 3.8と互換性のある依存関係をユーザー領域へ入れます。

   ```sh
   python -m pip install --target ~/private/xrelay/python -r ~/private/xclient_ios12/sakura/requirements.txt
   ```

   SakuraのPythonはOpenSSLが古い環境があるため、`urllib3`は1.26系に固定しています。

   リポジトリの`twitter_openapi_python`高水準パッケージはPython 3.10以上を要求するため、このCGIでは使わず、標準的なHTTP処理と`xclienttransaction`を使います。

3. `sakura/setup_config.py`をホームディレクトリなど`www`の外へ置き、SSHで対話実行します。公開APIカタログからWeb Appの既定ヘッダーを取得し、アカウントCookieは入力時に画面へ表示しません。

   ```sh
   python ~/private/xclient_ios12/sakura/setup_config.py
   ```

   Cookieの`auth_token`/`ct0`と、Cookie取得時のブラウザーUser-Agent/OSを対話入力します。必要ならX Web AppのBearer tokenを上書きできます。値は入力中に表示されず、設定ファイルは`600`、親ディレクトリは`700`で作成されます。表示されるCGIキーだけをiOSアプリの設定に入力してください。CookieやBearer tokenをチャットやGitHubへ貼らないでください。

4. iOSアプリには、`https://<公開ドメイン>/xclient`、プロフィール名（初期値`account1`）、CGIキーを設定し、接続テストを行います。SSHホスト名`www3414.sakura.ne.jp`はWebサイトの公開URLとは限りません。

## 更新

`requests.ndjson`のGraphQL query IDやfeature flagが古くなった場合、リポジトリのカタログを更新して再転送してください。`xclienttransaction`の素材はCGIがXから取得し、HTMLからURLを見つけられない場合は`TwitterInternalAPIDocument`の`ScriptLoadJson.json`を参照します。素材は`~/private/xrelay/tid-cache/`に12時間キャッシュします。Xから401/403が返る場合は、認証Cookieやブラウザー情報が失効していないか確認してください。
