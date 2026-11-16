# X Relay Client

iOS 12以上で動作するUIKit製のXクライアントです。アプリはCGIキーのみをKeychainに保存し、XのCookieやCSRFトークンは保存しません。CGIは、サーバーの公開領域外に置かれた設定からXのログインセッションを読み取ります。

## リリース

最新版は [GitHub Releases](https://github.com/mizuki20070314/X_client_ios12/releases) から取得できます。

配布IPAはActionsで生成した署名なしIPAです。Impactorなどで再署名する場合も、`Payload/XRelayClient.app` がIPA直下にある標準構造で生成されています。App Store配布や実機へのインストールには、Apple Developerの証明書・プロビジョニングプロファイルで再署名してください。Simulatorでの動作確認済みアプリは、同じReleaseのスクリーンショットとともに公開されます。

## ビルド

Xcodeプロジェクトは [XcodeGen](https://github.com/yonaskolb/XcodeGen) で `ios/project.yml` から生成します。`.xcodeproj` はリポジトリにコミットしません。

```sh
brew install xcodegen
cd ios
xcodegen generate
open XRelayClient.xcodeproj
```

- Xcode 16.4（iOS 18 SDK）でビルドし、デプロイ先は iOS 12.0 です。
- GitHub Actions（`.github/workflows/ios.yml`）は macOS 上で、シミュレーター向けと端末向けのビルド、署名なしIPA（`XRelayClient-<sha>` artifact）の作成、iPhone SE (3rd generation) での起動とスクリーンショット（`screenshots` artifact）を行います。

## 起動

1. `sakura/README.md`の手順でPython CGIを設置し、XセッションとCGIキーを設定します。

   `sakura/setup_config.py`は`www`の外に置き、SSHで実行します。

2. 上の手順で `XRelayClient.xcodeproj` を開き、iOS 12以上の端末またはシミュレータを選択して実行します。
3. 初回起動時に開く「設定とプライバシー」で、リレーURL、プロフィール名（任意）、CGIキーを入力し、「接続テスト」を実行してから「保存」します。公開サーバーには`https://`を使用してください。

## 機能

- 4つのタブ（ホーム、検索、通知、メッセージ）と、アバターから開くドロワー（プロフィール、履歴、設定、ダークモード）
- ホーム（おすすめ／フォロー中）、検索（話題・最新・ユーザー・メディア）、通知（すべて／@ポスト）
- ポストの詳細、返信、引用、投稿、削除、いいね、リポスト、ブックマーク、共有
- プロフィール（ポスト・返信・メディア・いいね）、フォロー／フォロワー一覧、フォロー・ミュート・ブロック
- 画像・動画・GIFの表示（画像は拡大・縮小できます）
- 履歴（ブックマーク・いいね）
- ダークモード（ライト／ダークブルー／ブラック）
- 設定：リレーURL・プロフィール名・CGIキー（Keychain）、接続テスト、画像キャッシュ削除
- メッセージ（DM）は未対応で、画面枠のみです。

queryIdやfeature flagはアプリに固定せず、公開領域の`/requests.ndjson`から取得します。X Web App側で内部APIが変更された場合は、CGIとカタログを更新してください。
