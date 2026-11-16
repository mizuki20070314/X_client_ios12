import UIKit

extension Notification.Name {
    /// Posted after a post was deleted. The object is the post id (String).
    static let tweetDeleted = Notification.Name("TweetDeleted")
    /// Posted after a post was created. The object is the new Tweet (or nil); userInfo["replyTo"] is the id it answers.
    static let tweetCreated = Notification.Name("TweetCreated")
}

/// Actions on a post (ui-spec §4.6). Each action changes the model first, then asks the relay. When the relay refuses,
/// the change is taken back and the error is shown as a toast.
enum TweetActions {
    static func reply(to tweet: Tweet) {
        Router.openCompose(replyTo: tweet)
    }

    /// Repost (or take it back), and quote.
    static func showRepostMenu(for tweet: Tweet) {
        let repostTitle = tweet.retweeted ? "リポストを取り消す" : "リポスト"
        let items: [BottomSheetItem] = [
            BottomSheetItem(icon: .repost, title: repostTitle, handler: {
                TweetActions.toggleRepost(tweet)
            }),
            BottomSheetItem(icon: .pencil, title: "引用", handler: {
                Router.openCompose(quote: tweet)
            }),
        ]
        BottomSheet.present(from: nil, items: items)
    }

    static func toggleRepost(_ tweet: Tweet) {
        let on = !tweet.retweeted
        tweet.retweeted = on
        tweet.retweetCount = TweetActions.adjusted(tweet.retweetCount, by: on ? 1 : -1)
        tweet.notifyChanged()
        RelayClient.shared.setRetweet(tweetID: tweet.id, on: on) { error in
            guard let error = error else { return }
            // only a change that nothing has overwritten since is taken back
            if tweet.retweeted == on {
                tweet.retweeted = !on
                tweet.retweetCount = TweetActions.adjusted(tweet.retweetCount, by: on ? -1 : 1)
                tweet.notifyChanged()
            }
            Toast.show(error.localizedDescription)
        }
    }

    static func toggleLike(_ tweet: Tweet) {
        let on = !tweet.liked
        tweet.liked = on
        tweet.likeCount = TweetActions.adjusted(tweet.likeCount, by: on ? 1 : -1)
        tweet.notifyChanged()
        RelayClient.shared.setLike(tweetID: tweet.id, on: on) { error in
            guard let error = error else { return }
            if tweet.liked == on {
                tweet.liked = !on
                tweet.likeCount = TweetActions.adjusted(tweet.likeCount, by: on ? -1 : 1)
                tweet.notifyChanged()
            }
            Toast.show(error.localizedDescription)
        }
    }

    static func toggleBookmark(_ tweet: Tweet) {
        let on = !tweet.bookmarked
        tweet.bookmarked = on
        tweet.bookmarkCount = TweetActions.adjusted(tweet.bookmarkCount, by: on ? 1 : -1)
        tweet.notifyChanged()
        RelayClient.shared.setBookmark(tweetID: tweet.id, on: on) { error in
            guard let error = error else {
                Toast.show(on ? "ブックマークに追加しました" : "ブックマークから削除しました")
                return
            }
            if tweet.bookmarked == on {
                tweet.bookmarked = !on
                tweet.bookmarkCount = TweetActions.adjusted(tweet.bookmarkCount, by: on ? -1 : 1)
                tweet.notifyChanged()
            }
            Toast.show(error.localizedDescription)
        }
    }

    /// Copy the link, or share it through the system sheet.
    static func showShareMenu(for tweet: Tweet) {
        guard let url = tweet.permalink else { return }
        let items: [BottomSheetItem] = [
            BottomSheetItem(icon: .copy, title: "リンクをコピー", handler: {
                TweetActions.copyLink(url)
            }),
            BottomSheetItem(icon: .external, title: "共有する…", handler: {
                TweetActions.share(url)
            }),
        ]
        BottomSheet.present(from: nil, items: items)
    }

    /// Delete (own posts only), copy the link, and the account actions for someone else's post.
    static func showOverflowMenu(for tweet: Tweet) {
        var items: [BottomSheetItem] = []
        if tweet.user.id == Session.shared.me?.id {
            items.append(BottomSheetItem(icon: .trash, title: "ポストを削除", style: .destructive, handler: {
                TweetActions.delete(tweet)
            }))
        } else {
            items.append(contentsOf: accountItems(for: tweet.user))
        }
        if let url = tweet.permalink {
            items.append(BottomSheetItem(icon: .link, title: "リンクをコピー", handler: {
                TweetActions.copyLink(url)
            }))
        }
        BottomSheet.present(from: nil, items: items)
    }

    /// Asks first, then deletes the post on the relay and posts `tweetDeleted` with its id.
    static func delete(_ tweet: Tweet) {
        let tweetID = tweet.id
        presentConfirmation(title: "ポストを削除しますか？",
                message: "この操作は取り消せません。プロフィール、あなたをフォローしているアカウントのタイムライン、検索結果からポストが削除されます。",
                actionTitle: "削除", destructive: true) {
            RelayClient.shared.deleteTweet(id: tweetID) { error in
                if let error = error {
                    Toast.show(error.localizedDescription)
                    return
                }
                NotificationCenter.default.post(name: .tweetDeleted, object: tweetID)
            }
        }
    }

    private static func accountItems(for user: User) -> [BottomSheetItem] {
        let handle = "@" + user.handle
        let followIcon: IconName = user.following ? .userMinus : .userPlus
        let followTitle = user.following ? handle + "さんのフォローを解除" : handle + "さんをフォロー"
        let muteTitle = user.muting ? "ミュートを解除" : handle + "さんをミュート"
        let blockTitle = user.blocking ? "ブロックを解除" : handle + "さんをブロック"
        return [
            BottomSheetItem(icon: followIcon, title: followTitle, handler: {
                UserActions.toggleFollow(user)
            }),
            BottomSheetItem(icon: .volumeOff, title: muteTitle, handler: {
                UserActions.toggleMute(user)
            }),
            BottomSheetItem(icon: .ban, title: blockTitle, style: .destructive, handler: {
                UserActions.toggleBlock(user)
            }),
        ]
    }

    private static func copyLink(_ url: URL) {
        UIPasteboard.general.string = url.absoluteString
        Toast.show("コピーしました")
    }

    private static func share(_ url: URL) {
        guard let presenter = Router.topViewController else { return }
        let activity = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        // on iPad the activity sheet is a popover that needs an anchor; on iPhone the property is ignored
        if let popover = activity.popoverPresentationController {
            let center = CGRect(x: presenter.view.bounds.midX, y: presenter.view.bounds.midY, width: 0, height: 0)
            popover.sourceView = presenter.view
            popover.sourceRect = center
        }
        presenter.present(activity, animated: true, completion: nil)
    }

    private static func adjusted(_ count: Int, by delta: Int) -> Int {
        return max(0, count + delta)
    }
}

/// Follow, mute and block (ui-spec §4.6). The same pattern as TweetActions: model first, relay second, revert on error.
enum UserActions {
    static func toggleFollow(_ user: User) {
        // blocked accounts are unblocked here, after a confirmation
        if user.blocking {
            let handle = "@" + user.handle
            presentConfirmation(title: "ブロックを解除しますか？", message: handle + "さんのブロックを解除します。",
                    actionTitle: "解除", destructive: false) {
                UserActions.setBlocked(user, on: false)
            }
            return
        }
        let on = !user.following
        user.following = on
        UserActions.adjustFollowers(of: user, by: on ? 1 : -1)
        user.notifyChanged()
        RelayClient.shared.setFollow(userID: user.id, on: on) { error in
            guard let error = error else { return }
            if user.following == on {
                user.following = !on
                UserActions.adjustFollowers(of: user, by: on ? -1 : 1)
                user.notifyChanged()
            }
            Toast.show(error.localizedDescription)
        }
    }

    static func toggleMute(_ user: User) {
        let on = !user.muting
        user.muting = on
        user.notifyChanged()
        RelayClient.shared.setMute(userID: user.id, on: on) { error in
            guard let error = error else {
                Toast.show(on ? "@\(user.handle)さんをミュートしました" : "ミュートを解除しました")
                return
            }
            if user.muting == on {
                user.muting = !on
                user.notifyChanged()
            }
            Toast.show(error.localizedDescription)
        }
    }

    /// Blocking asks first; unblocking does not.
    static func toggleBlock(_ user: User) {
        if user.blocking {
            setBlocked(user, on: false)
            return
        }
        let handle = "@" + user.handle
        presentConfirmation(title: handle + "さんをブロックしますか？",
                message: "ブロックすると、このアカウントはあなたをフォローできなくなり、あなたのポストを見ることもできなくなります。",
                actionTitle: "ブロック", destructive: true) {
            UserActions.setBlocked(user, on: true)
        }
    }

    private static func setBlocked(_ user: User, on: Bool) {
        user.blocking = on
        user.notifyChanged()
        RelayClient.shared.setBlock(userID: user.id, on: on) { error in
            guard let error = error else { return }
            if user.blocking == on {
                user.blocking = !on
                user.notifyChanged()
            }
            Toast.show(error.localizedDescription)
        }
    }

    /// The follower count of a profile that is loaded in full moves with the follow.
    private static func adjustFollowers(of user: User, by delta: Int) {
        guard user.isFull else { return }
        user.followers = max(0, user.followers + delta)
    }
}

/// A confirmation alert with the action and a cancel button, shown over the top-most controller.
fileprivate func presentConfirmation(title: String, message: String, actionTitle: String, destructive: Bool,
                                     action: @escaping () -> Void) {
    guard let presenter = Router.topViewController else { return }
    let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
    let style: UIAlertAction.Style = destructive ? .destructive : .default
    alert.addAction(UIAlertAction(title: actionTitle, style: style, handler: { _ in
        action()
    }))
    alert.addAction(UIAlertAction(title: "キャンセル", style: .cancel, handler: nil))
    presenter.present(alert, animated: true, completion: nil)
}
