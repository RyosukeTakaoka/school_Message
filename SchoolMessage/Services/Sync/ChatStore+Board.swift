import Foundation

/// 掲示板の未読件数.
///
/// 掲示板は会話に紐づかない「みんなで見る場所」で, チャットの一覧と違って
/// 開いている間だけポーリングする(`BoardView` 参照). そのため未読件数も
/// リアルタイムには追従せず, サインイン・前面復帰・掲示板の表示・書き込みの
/// 取得といった, もともと通信が発生する場面に相乗りして更新する.
extension ChatStore {

    /// 掲示板の未読件数を, サーバから取得し直して更新する.
    func refreshBoardUnreadCount() async {
        guard let threads = try? await backend.fetchBoardThreads() else { return }
        updateBoardUnreadCount(from: threads)
    }

    /// 取得済みのスレッド一覧から未読件数を計算し直す.
    ///
    /// `BoardView` がスレッド一覧を取得する場面(表示・引き下げ更新・自動更新)に
    /// 相乗りする. 未読件数を出すためだけにもう一度サーバへ問い合わせない.
    func updateBoardUnreadCount(from threads: [BoardThread]) {
        boardUnreadCount = threads.reduce(0) { $0 + unreadPostCount(in: $1) }
    }

    /// そのスレッドの中の未読件数(一覧の各行に出すバッジ用).
    func unreadPostCount(in thread: BoardThread) -> Int {
        max(0, thread.postCount - boardReadState.seenPostCount(for: thread.id))
    }

    /// スレッドを開いて, 実際に取得できた書き込み数までを読んだことにする.
    ///
    /// `thread.postCount`(一覧を取得した時点の数)ではなく, 呼び出し側が
    /// 実際に取得した書き込みの数を渡してもらう. スレッドを開いてから
    /// 一覧を取得するまでの間に新しい書き込みが増えていることがあるため.
    func markBoardThreadSeen(_ thread: BoardThread, postCount: Int) {
        // `thread.postCount`(一覧を取得した時点の数)ではなく, 実際に取得できた
        // `postCount` との差で計算する. 開いてから一覧を取り直すまでの間に
        // 新しい書き込みが増えていることがあり, そちらのほうが正確なため.
        let unread = max(0, postCount - boardReadState.seenPostCount(for: thread.id))
        guard unread > 0 else { return }
        boardReadState.markSeen(thread.id, postCount: postCount)
        boardUnreadCount = max(0, boardUnreadCount - unread)
    }
}
