# X Client for iOS 12+

UIKit製のiOS 12以上対応Xクライアントです。公式Android版を参考に、タイムライン、検索、投稿・返信、通知、プロフィールなどの画面と操作を実装しています。リポジトリにはiOSアプリと、さくらの共用サーバー向けPython CGIを含みます。

## バックエンド

`sakura/www/cgi-bin/xrelay.cgi`はブラウザーやPlaywrightを起動せず、CGIの各リクエストからXのWeb内部GraphQL APIへ直接HTTPリクエストを送ります。認証セッションは、利用者自身がエクスポートした`auth_token`と`ct0`を、公開領域外の`~/private/xrelay/config.json`に保存して使います。CGIはホームタイムライン、検索、テキスト投稿・返信を許可します。

このX APIは非公式で、仕様・認証・query ID・transaction IDが変わると動かなくなる場合があります。ログイン自動化や検知回避は行いません。XのCookieとBearer tokenはリポジトリやチャットに保存しないでください。

さくらへの配置・設定は[`sakura/README.md`](sakura/README.md)を参照してください。CGIキーはアプリのKeychainに保存され、XのCookieはサーバーの非公開ディレクトリから読み込みます。

## iOSクライアント

XcodeGen（`brew install xcodegen`）で `ios/project.yml` から Xcode プロジェクトを生成し、開きます。`.xcodeproj` はリポジトリにコミットしません。

```sh
cd ios
xcodegen generate
open XRelayClient.xcodeproj
```

アプリの「設定とプライバシー」でCGIを置いたサブディレクトリのHTTPS URL（例：`https://your-domain.example/xclient`）、プロフィール名、CGIキーを入力して接続テストを行います。初回起動時は設定画面が自動で開くので、そこでサーバーを登録してください。

主な機能:

- 公式Android版を参考にした4タブ（ホーム、検索、通知、メッセージ）と、アバターから開くドロワー
- ホーム（おすすめ／フォロー中）、検索（話題・最新・ユーザー・メディア）、通知（すべて／@ポスト）
- ポストの詳細、返信・引用・投稿、いいね・リポスト・ブックマーク、共有
- プロフィール、フォロー／フォロワー一覧、フォロー・ミュート・ブロック、画像・動画・GIFの表示
- 履歴（ブックマーク・いいね）
- ライト／ダークブルー／ブラックのテーマ（iOS 13以降は端末の設定に合わせる）
- CGIキーのKeychain保存、接続テスト、画像キャッシュ削除
- DM（メッセージ）は現在のCGIでは未対応で、画面枠のみです。

## GitHub Actions

`.github/workflows/ios.yml` が macOS runner で XcodeGen のプロジェクトをビルドします。シミュレーター向けのビルド、署名なしIPA（`XRelayClient-<sha>` artifact）の作成、iPhone SE (3rd generation) での起動とスクリーンショット（`screenshots` artifact）を行います。実機インストールにはAppleの署名・プロビジョニングが必要です。タグ`ios-v*`では `.github/workflows/ios-release.yml` がRelease用IPAを作成します。
