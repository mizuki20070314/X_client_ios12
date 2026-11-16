import UIKit

/// The followers or the accounts a user follows, pushed from the counts on a profile.
final class UserListViewController: BaseViewController {
    private let userID: String
    private let followers: Bool
    private var timeline: TimelineViewController?
    private var didStartLoading = false

    init(userID: String, followers: Bool) {
        self.userID = userID
        self.followers = followers
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        topBar.title = followers ? "フォロワー" : "フォロー中"
        topBar.setBackButton { [weak self] in
            self?.navigationController?.popViewController(animated: true)
        }

        let timeline = TimelineViewController(source: .follows(userID: userID, followers: followers))
        addChild(timeline)
        view.addSubview(timeline.view)
        timeline.didMove(toParent: self)
        self.timeline = timeline
    }

    override func layoutContent() {
        let width = view.bounds.width
        let top = contentTop
        timeline?.view.frame = CGRect(x: 0, y: top, width: width, height: max(0, view.bounds.height - top))
        // the first load waits for a real width, so the rows are measured once
        if !didStartLoading && width > 0 {
            didStartLoading = true
            timeline?.loadIfNeeded()
        }
    }
}
