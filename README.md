# X Client for iOS 12+

UIKit製のXクライアントです。タイムライン、キーワード検索、テキスト投稿を備え、X風のライトテーマで表示します。リポジトリにはiOSアプリと、さくらの共用サーバー向けPython CGIを含みます。

## バックエンド

`sakura/www/cgi-bin/xrelay.cgi`はブラウザーやPlaywrightを起動せず、CGIの各リクエストからXのWeb内部GraphQL APIへ直接HTTPリクエストを送ります。認証セッションは、利用者自身がエクスポートした`auth_token`と`ct0`を、公開領域外の`~/private/xrelay/config.json`に保存して使います。CGIはホームタイムライン、検索、テキスト投稿だけを許可します。

このX APIは非公式で、仕様・認証・query ID・transaction IDが変わると動かなくなる場合があります。ログイン自動化や検知回避は行いません。XのCookieとBearer tokenはリポジトリやチャットに保存しないでください。

さくらへの配置・設定は[`sakura/README.md`](sakura/README.md)を参照してください。CGIキーはアプリのKeychainに保存され、XのCookieはサーバーの非公開ディレクトリから読み込みます。

## iOSクライアント

```sh
open ios/XRelayClient.xcodeproj
```

アプリの「設定」でCGIを置いたサブディレクトリのHTTPS URL（例：`https://your-domain.example/xclient`）、プロフィール名、CGIキーを入力して接続テストを行います。初回は「設定」画面を開いてサーバーを登録してください。

主な機能:

- X風のタイムライン・検索・投稿画面
- 投稿アバター表示とPull to Refresh
- CGIキーのKeychain保存
- プロフィール切り替え

## GitHub Actions

`ios/XRelayClient.xcodeproj`をmacOS runnerでシミュレーター確認し、署名なしIPAとSimulatorアプリをArtifactsへアップロードします。実機インストールにはAppleの署名・プロビジョニングが必要です。タグ`ios-v*`ではRelease用IPAを作成します。
