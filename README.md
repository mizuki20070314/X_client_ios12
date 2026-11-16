# X Client for iOS 12+

UIKit製のiOS 12以上対応Xクライアントです。公式Android版を参考に、タイムライン、検索、投稿・返信を中心とした画面と操作を実装しています。リポジトリにはiOSアプリと、さくらの共用サーバー向けPython CGIを含みます。

## バックエンド

`sakura/www/cgi-bin/xrelay.cgi`はブラウザーやPlaywrightを起動せず、CGIの各リクエストからXのWeb内部GraphQL APIへ直接HTTPリクエストを送ります。認証セッションは、利用者自身がエクスポートした`auth_token`と`ct0`を、公開領域外の`~/private/xrelay/config.json`に保存して使います。CGIはホームタイムライン、検索、テキスト投稿・返信を許可します。

このX APIは非公式で、仕様・認証・query ID・transaction IDが変わると動かなくなる場合があります。ログイン自動化や検知回避は行いません。XのCookieとBearer tokenはリポジトリやチャットに保存しないでください。

さくらへの配置・設定は[`sakura/README.md`](sakura/README.md)を参照してください。CGIキーはアプリのKeychainに保存され、XのCookieはサーバーの非公開ディレクトリから読み込みます。

## iOSクライアント

```sh
open ios/XRelayClient.xcodeproj
```

アプリの「設定」でCGIを置いたサブディレクトリのHTTPS URL（例：`https://your-domain.example/xclient`）、プロフィール名、CGIキーを入力して接続テストを行います。初回は「設定」画面を開いてサーバーを登録してください。

主な機能:

- 公式Android版を参考にした5タブ構成とライト／ダーク表示
- タイムラインのアバター、認証バッジ、時刻、画像、反応数表示とPull to Refresh
- 「話題／最新」検索、テキスト投稿、返信、ポスト共有
- 通知、DM、いいね、リポストは現在のCGIでは未対応
- CGIキーのKeychain保存
- プロフィール切り替え

## GitHub Actions

`ios/XRelayClient.xcodeproj`をmacOS runnerでシミュレーター確認し、署名なしIPAとSimulatorアプリをArtifactsへアップロードします。実機インストールにはAppleの署名・プロビジョニングが必要です。タグ`ios-v*`ではRelease用IPAを作成します。
