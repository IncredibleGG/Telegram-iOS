import Foundation
import UIKit
import AsyncDisplayKit
import Display
import SwiftSignalKit
import Postbox
import TelegramCore
import TelegramPresentationData
import AccountContext
import TelegramUIPreferences
import ChatHistoryEntry
import ChatControllerInteraction
import ChatMessageItem
import ChatMessageItemCommon
import ChatMessageItemImpl
import ContextUI
import UndoUI
import AppBundle

// LuminaGram「隱藏重複廣告」(hide repeated ads), stage 2: the chat list side.
//
//  - The rendered entries (fold rows, headers, trial labels) are built in LuminaAdShieldFoldEntries.swift.
//  - `LuminaAdShieldFoldItem` / `LuminaAdShieldFoldItemNode`: the three rows (fold row, header, trial label).
//  - `LuminaAdShieldFoldInteraction`: what the rows do (show, fold again, not an ad, off in this group) and the
//    once-per-chat "all new messages were folded" toast. One per ChatHistoryListNodeImpl; it always acts on the
//    node's current AdShield session.
//
// Only the main chat history of a group (or a forum topic) ever gets a session, so search, shared media, the pinned
// list, scheduled messages, previews in the chat list, the admin log and notifications are untouched. Nothing here
// logs.

// MARK: - Texts

enum LuminaAdShieldFoldTexts {
    static func foldRow(_ data: LuminaAdFoldEntryData) -> String {
        let count = max(1, data.unitCount)
        if data.containsReplyToMe {
            if count == 1 {
                return LuminaL10n.tr("1 repeated message replying to you folded (suspected ad) · Tap to show")
            }
            return String(format: LuminaL10n.tr("%@ repeated messages replying to you folded (suspected ads) · Tap to show"), "\(count)")
        }
        if count == 1 {
            if data.occurrence > 0 {
                return String(format: LuminaL10n.tr("1 repeated message folded (suspected ad, seen %@ times in 7 days) · Tap to show"), "\(data.occurrence)")
            }
            return LuminaL10n.tr("1 repeated message folded (suspected ad) · Tap to show")
        }
        return String(format: LuminaL10n.tr("%@ repeated messages folded (suspected ads) · Tap to show"), "\(count)")
    }

    static var headerTitle: String {
        return LuminaL10n.tr("Repeated messages (suspected ads)")
    }

    static var fold: String {
        return LuminaL10n.tr("Fold")
    }

    static var notAd: String {
        return LuminaL10n.tr("Not an Ad")
    }

    static var show: String {
        return LuminaL10n.tr("Show")
    }

    static var trialLabel: String {
        return LuminaL10n.tr("Suspected repeated ad")
    }

    static var allNewFolded: String {
        return LuminaL10n.tr("All new messages this time are repeated ads and were folded")
    }

    static var showHint: String {
        return LuminaL10n.tr("Double-tap to show these messages")
    }
}

// MARK: - ChatHistoryListNodeImpl hooks

extension ChatHistoryListNodeImpl {
    /// Init and updateChatLocation: wire the (new) observer's session to the fold rows, the history combine and the
    /// all-folded toast. Without a session (anything but a group's main history) the version stays 0.
    func luminaAdShieldAttach() {
        self.luminaAdShieldFold.historyNode = self
        if let session = self.luminaAdShield?.session {
            let fold = self.luminaAdShieldFold
            session.allNewFolded = { [weak fold, weak session] messageIds in
                guard let fold, let session else {
                    return
                }
                fold.presentAllNewFolded(session: session, messageIds: messageIds)
            }
            self.luminaAdShieldVersionPromise.set(session.version)
        } else {
            self.luminaAdShieldVersionPromise.set(.single(0))
        }
    }

    /// A jump to a message of this chat (reply quote, search result, link, pinned bar, opening at a message): unfold
    /// its segment so that the message is there to scroll to. Dispatched, so that a location set while a history
    /// transition is being computed never re-enters it; the new history view arrives later anyway. Nothing at all
    /// while the feature is not in effect here.
    func luminaAdShieldExpandJumpTarget(_ location: ChatHistoryLocationInput?) {
        guard let observer = self.luminaAdShield, observer.session.isActive, let target = luminaAdShieldJumpTarget(location), target.peerId == observer.peerId, target.namespace == Namespaces.Message.Cloud else {
            return
        }
        let session = observer.session
        Queue.mainQueue().justDispatch {
            session.expand([target.id])
        }
    }

    /// The visible-range handling reports the message rows on screen (never the hidden members of a folded segment)
    /// for the "nothing vanishes under the reader" rule. `range` indexes `entries` (ascending), both ends included.
    func luminaAdShieldNoteDisplayed(_ entries: [ChatHistoryEntry], range: (Int, Int)) {
        guard let observer = self.luminaAdShield, observer.session.isActive else {
            return
        }
        var ids: [Int32] = []
        if range.0 >= 0 && range.0 <= range.1 && range.1 < entries.count {
            for i in range.0 ... range.1 {
                switch entries[i] {
                case let .MessageEntry(message, _, _, _, _, _):
                    if message.id.peerId == observer.peerId && message.id.namespace == Namespaces.Message.Cloud {
                        ids.append(message.id.id)
                    }
                case let .MessageGroupEntry(_, messages, _):
                    for (message, _, _, _, _) in messages where message.id.peerId == observer.peerId && message.id.namespace == Namespaces.Message.Cloud {
                        ids.append(message.id.id)
                    }
                default:
                    break
                }
            }
        }
        observer.session.noteDisplayed(ids)
    }
}

// MARK: - Interaction

/// What the AdShield rows of one ChatHistoryListNodeImpl do. Always acts on the node's current session (it is
/// replaced when the chat location changes). Main thread only.
final class LuminaAdShieldFoldInteraction {
    weak var historyNode: ChatHistoryListNodeImpl?
    private let context: AccountContext
    private let controllerInteraction: ChatControllerInteraction
    private let toastWaitDisposable = MetaDisposable()

    init(context: AccountContext, controllerInteraction: ChatControllerInteraction) {
        self.context = context
        self.controllerInteraction = controllerInteraction
    }

    deinit {
        self.toastWaitDisposable.dispose()
    }

    private var observer: LuminaAdShieldHistoryObserver? {
        return self.historyNode?.luminaAdShield
    }

    /// Tap on the fold row (or 「顯示」): show the whole segment.
    func show(_ data: LuminaAdFoldEntryData) {
        self.observer?.session.expand(data.messageIds.map { $0.id })
    }

    /// 「收合」 on the header of an expanded segment.
    func fold(_ data: LuminaAdFoldEntryData) {
        self.observer?.session.collapse(data.messageIds.map { $0.id })
    }

    /// 「不是廣告」: remember the cluster for 90 days and unfold it.
    func notAd(_ data: LuminaAdFoldEntryData) {
        guard let session = self.observer?.session, let head = data.messageIds.first else {
            return
        }
        session.markNotAd(head.id, segmentIds: data.messageIds.map { $0.id })
    }

    /// 「在此群關閉」
    func turnOffInThisGroup() {
        guard let observer = self.observer else {
            return
        }
        let controllerInteraction = self.controllerInteraction
        luminaAdShieldSetChatMode(context: self.context, peerId: observer.peerId, mode: .off, present: { controller in
            controllerInteraction.presentController(controller, nil)
        })
    }

    /// Long press / secondary click on the fold row: 「顯示」「不是廣告」「在此群關閉」.
    func openMenu(_ data: LuminaAdFoldEntryData, sourceView: UIView) {
        let presentationData = self.context.sharedContext.currentPresentationData.with { $0 }
        var items: [ContextMenuItem] = []
        items.append(.action(ContextMenuActionItem(text: LuminaAdShieldFoldTexts.show, icon: { theme in
            return generateTintedImage(image: UIImage(bundleImageName: "Chat/Context Menu/Eye"), color: theme.contextMenu.primaryColor)
        }, action: { [weak self] c, _ in
            c?.dismiss(completion: {
                self?.show(data)
            })
        })))
        items.append(.action(ContextMenuActionItem(text: LuminaAdShieldFoldTexts.notAd, icon: { theme in
            return generateTintedImage(image: UIImage(bundleImageName: "Chat/Context Menu/Check"), color: theme.contextMenu.primaryColor)
        }, action: { [weak self] c, _ in
            c?.dismiss(completion: {
                self?.notAd(data)
            })
        })))
        items.append(.action(ContextMenuActionItem(text: LuminaAdShieldTexts.modeLabel(.off, globalOn: false), icon: { theme in
            return generateTintedImage(image: UIImage(bundleImageName: "Chat/Context Menu/AntiSpam"), color: theme.contextMenu.primaryColor)
        }, action: { [weak self] c, _ in
            c?.dismiss(completion: {
                self?.turnOffInThisGroup()
            })
        })))
        let source: ContextContentSource = .reference(LuminaAdShieldFoldMenuSource(sourceView: sourceView))
        let controller = makeContextController(presentationData: presentationData, source: source, items: .single(ContextController.Items(content: .list(items))), gesture: nil)
        self.controllerInteraction.presentGlobalOverlayController(controller, nil)
    }

    /// 「這次的新訊息都是重複廣告，已收合」, once per chat per app run, only while the chat is really on screen: it waits up
    /// to 3 s for the chat to be able to read (the opening transition), and never shows in a preview, which cannot.
    func presentAllNewFolded(session: LuminaAdShieldChatSession, messageIds: [Int32]) {
        if self.controllerInteraction.canReadHistory {
            self.presentAllNewFoldedNow(session: session, messageIds: messageIds)
            return
        }
        guard let historyNode = self.historyNode else {
            return
        }
        self.toastWaitDisposable.set((historyNode.canReadHistory.get()
        |> filter { $0 }
        |> take(1)
        |> timeout(3.0, queue: Queue.mainQueue(), alternate: .complete())
        |> deliverOnMainQueue).startStrict(next: { [weak self, weak session] _ in
            guard let self, let session else {
                return
            }
            self.presentAllNewFoldedNow(session: session, messageIds: messageIds)
        }))
    }

    private func presentAllNewFoldedNow(session: LuminaAdShieldChatSession, messageIds: [Int32]) {
        // Claimed here, so that a toast that could not be shown does not use up the chat's one toast of this run; the
        // claim checks again that every one of these messages still folds.
        if !session.claimAllNewFoldedToast(newMessageIds: messageIds) {
            return
        }
        let presentationData = self.context.sharedContext.currentPresentationData.with { $0 }
        self.controllerInteraction.presentControllerInCurrent(UndoOverlayController(presentationData: presentationData, content: .info(title: nil, text: LuminaAdShieldFoldTexts.allNewFolded, timeout: nil, customUndoText: nil), elevatedLayout: false, action: { _ in
            return false
        }), nil)
    }
}

private final class LuminaAdShieldFoldMenuSource: ContextReferenceContentSource {
    private let sourceView: UIView

    init(sourceView: UIView) {
        self.sourceView = sourceView
    }

    func transitionInfo() -> ContextControllerReferenceViewInfo? {
        return ContextControllerReferenceViewInfo(referenceView: self.sourceView, contentAreaInScreenSpace: mainWindowScreenBounds)
    }
}

// MARK: - Rows

private let luminaAdShieldRowFont = Font.regular(13.0)
private let luminaAdShieldActionFont = Font.semibold(13.0)
private let luminaAdShieldLabelFont = Font.regular(11.0)

/// A fold row, the header of an expanded segment, or a trial label (`LuminaAdFoldEntryData.Kind`).
final class LuminaAdShieldFoldItem: ListViewItem, ChatHistoryItemWithHeaders {
    let index: EngineMessage.Index
    let data: LuminaAdFoldEntryData
    let presentationData: ChatPresentationData
    let controllerInteraction: ChatControllerInteraction
    let interaction: LuminaAdShieldFoldInteraction?
    let header: ChatMessageDateHeader

    // Like the unread separator: the row belongs to its day's date header run (CoreList reads it off the item).
    var headers: [ListViewItemHeader] {
        return [self.header]
    }

    // Neighbours treat the row like the unread separator: no bubble merging across it, same date run.
    var neighborDescriptor: AnyEquatable {
        return AnyEquatable(ChatHistoryItemNeighbor.unread(dateHeaderId: self.header.id))
    }

    init(index: EngineMessage.Index, data: LuminaAdFoldEntryData, presentationData: ChatPresentationData, context: AccountContext, controllerInteraction: ChatControllerInteraction, interaction: LuminaAdShieldFoldInteraction?) {
        self.index = index
        self.data = data
        self.presentationData = presentationData
        self.controllerInteraction = controllerInteraction
        self.interaction = interaction
        self.header = ChatMessageDateHeader(timestamp: index.timestamp, separableThreadId: nil, scheduled: false, displayHeader: nil, presentationData: presentationData, controllerInteraction: controllerInteraction, context: context)
    }

    func nodeConfiguredForParams(async: @escaping (@escaping () -> Void) -> Void, params: ListViewItemLayoutParams, synchronousLoads: Bool, neighbors: ListViewItemNeighbors, completion: @escaping (ListViewItemNode, @escaping () -> (Signal<Void, NoError>?, (ListViewItemApply) -> Void)) -> Void) {
        async {
            let node = LuminaAdShieldFoldItemNode()
            let dateAtBottom = !chatItemsHaveCommonDateHeader(self.header.id, ChatHistoryItemNeighbors(neighbors).next)
            let (layout, apply) = node.asyncLayout()(self, params, dateAtBottom)
            node.contentSize = layout.contentSize
            node.insets = layout.insets
            Queue.mainQueue().async {
                completion(node, {
                    return (nil, { _ in
                        apply(.None)
                    })
                })
            }
        }
    }

    func updateNode(async: @escaping (@escaping () -> Void) -> Void, node: @escaping () -> ListViewItemNode, params: ListViewItemLayoutParams, neighbors: ListViewItemNeighbors, animation: ListViewItemUpdateAnimation, completion: @escaping (ListViewItemNodeLayout, @escaping (ListViewItemApply) -> Void) -> Void) {
        Queue.mainQueue().async {
            guard let nodeValue = node() as? LuminaAdShieldFoldItemNode else {
                assertionFailure()
                return
            }
            let nodeLayout = nodeValue.asyncLayout()
            async {
                let dateAtBottom = !chatItemsHaveCommonDateHeader(self.header.id, ChatHistoryItemNeighbors(neighbors).next)
                let (layout, apply) = nodeLayout(self, params, dateAtBottom)
                Queue.mainQueue().async {
                    completion(layout, { _ in
                        apply(animation)
                    })
                }
            }
        }
    }
}

/// Lets the row's recognizers begin only on its pill or buttons, so taps elsewhere on the row reach the chat as before.
private final class LuminaAdShieldFoldGestureDelegate: NSObject, UIGestureRecognizerDelegate {
    var shouldBegin: ((UIGestureRecognizer) -> Bool)?

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        return self.shouldBegin?(gestureRecognizer) ?? false
    }
}

final class LuminaAdShieldFoldItemNode: ListViewItemNode {
    private(set) var item: LuminaAdShieldFoldItem?

    /// The pill; view-backed so that it can anchor the long-press menu.
    private let backgroundNode: ASDisplayNode
    /// Fold row text, header title or trial label.
    private let textNode: TextNode
    /// Header only: 「· 收合 · 不是廣告」.
    private let leadingSeparatorNode: TextNode
    private let foldNode: TextNode
    private let separatorNode: TextNode
    private let notAdNode: TextNode

    private let mainArea: AccessibilityAreaNode
    private let foldArea: AccessibilityAreaNode
    private let notAdArea: AccessibilityAreaNode

    private var pillFrame = CGRect()
    private var foldTapFrame: CGRect?
    private var notAdTapFrame: CGRect?
    private var gestureDelegate: LuminaAdShieldFoldGestureDelegate?

    private let layoutConstants = ChatMessageItemLayoutConstants.default

    /// The messages a fold row on screen reads (ChatHistoryListNode's read-state rows); nil for the other rows.
    var readIndices: [EngineMessage.Index]? {
        guard let item = self.item, item.data.kind == .folded else {
            return nil
        }
        return item.data.messageIndices
    }

    init() {
        self.backgroundNode = ASDisplayNode()
        self.backgroundNode.isUserInteractionEnabled = false

        self.textNode = TextNode()
        self.textNode.isUserInteractionEnabled = false
        self.leadingSeparatorNode = TextNode()
        self.leadingSeparatorNode.isUserInteractionEnabled = false
        self.foldNode = TextNode()
        self.foldNode.isUserInteractionEnabled = false
        self.separatorNode = TextNode()
        self.separatorNode.isUserInteractionEnabled = false
        self.notAdNode = TextNode()
        self.notAdNode.isUserInteractionEnabled = false

        self.mainArea = AccessibilityAreaNode()
        self.foldArea = AccessibilityAreaNode()
        self.notAdArea = AccessibilityAreaNode()

        super.init(layerBacked: false, rotated: true)

        self.addSubnode(self.backgroundNode)
        self.addSubnode(self.textNode)
        self.addSubnode(self.leadingSeparatorNode)
        self.addSubnode(self.foldNode)
        self.addSubnode(self.separatorNode)
        self.addSubnode(self.notAdNode)
        self.addSubnode(self.mainArea)
        self.addSubnode(self.foldArea)
        self.addSubnode(self.notAdArea)

        self.transform = CATransform3DMakeRotation(CGFloat.pi, 0.0, 0.0, 1.0)

        self.scrollPositioningInsets = UIEdgeInsets(top: 5.0, left: 0.0, bottom: 6.0, right: 0.0)
        self.canBeUsedAsScrollToItemAnchor = false
    }

    override func didLoad() {
        super.didLoad()

        let gestureDelegate = LuminaAdShieldFoldGestureDelegate()
        gestureDelegate.shouldBegin = { [weak self] recognizer in
            return self?.gestureShouldBegin(recognizer) ?? false
        }
        self.gestureDelegate = gestureDelegate

        let tapRecognizer = UITapGestureRecognizer(target: self, action: #selector(self.tapGesture(_:)))
        tapRecognizer.delegate = gestureDelegate
        self.view.addGestureRecognizer(tapRecognizer)

        let longPressRecognizer = UILongPressGestureRecognizer(target: self, action: #selector(self.longPressGesture(_:)))
        longPressRecognizer.delegate = gestureDelegate
        self.view.addGestureRecognizer(longPressRecognizer)

        if #available(iOS 13.4, *) {
            let secondaryClickRecognizer = UITapGestureRecognizer(target: self, action: #selector(self.secondaryClickGesture(_:)))
            secondaryClickRecognizer.buttonMaskRequired = .secondary
            secondaryClickRecognizer.delegate = gestureDelegate
            self.view.addGestureRecognizer(secondaryClickRecognizer)
        }
    }

    override func animateInsertion(_ currentTimestamp: Double, duration: Double, options: ListViewItemAnimationOptions) {
        super.animateInsertion(currentTimestamp, duration: duration, options: options)

        self.layer.animateAlpha(from: 0.0, to: 1.0, duration: 0.2)
    }

    override func animateAdded(_ currentTimestamp: Double, duration: Double) {
        self.layer.animateAlpha(from: 0.0, to: 1.0, duration: 0.2)
    }

    override func animateRemoved(_ currentTimestamp: Double, duration: Double) {
        super.animateRemoved(currentTimestamp, duration: duration)

        self.layer.animateAlpha(from: 1.0, to: 0.0, duration: 0.2, removeOnCompletion: false)
    }

    override func layoutForParams(_ params: ListViewItemLayoutParams, item: ListViewItem, neighbors: ListViewItemNeighbors) {
        if let item = item as? LuminaAdShieldFoldItem {
            let dateAtBottom = !chatItemsHaveCommonDateHeader(item.header.id, ChatHistoryItemNeighbors(neighbors).next)
            let (layout, apply) = self.asyncLayout()(item, params, dateAtBottom)
            apply(.None)
            self.contentSize = layout.contentSize
            self.insets = layout.insets
        }
    }

    override func headers() -> [ListViewItemHeader]? {
        if let item = self.item {
            return [item.header]
        } else {
            return nil
        }
    }

    func asyncLayout() -> (_ item: LuminaAdShieldFoldItem, _ params: ListViewItemLayoutParams, _ dateAtBottom: Bool) -> (ListViewItemNodeLayout, (ListViewItemUpdateAnimation) -> Void) {
        let makeTextLayout = TextNode.asyncLayout(self.textNode)
        let makeLeadingSeparatorLayout = TextNode.asyncLayout(self.leadingSeparatorNode)
        let makeFoldLayout = TextNode.asyncLayout(self.foldNode)
        let makeSeparatorLayout = TextNode.asyncLayout(self.separatorNode)
        let makeNotAdLayout = TextNode.asyncLayout(self.notAdNode)
        let layoutConstants = self.layoutConstants

        return { [weak self] item, params, dateAtBottom in
            let theme = item.presentationData.theme.theme
            let wallpaper = item.presentationData.theme.wallpaper
            let isBubbleless = !item.presentationData.chatBubbleCorners.bubbleMode
            let textColor: UIColor
            let fillColor: UIColor
            if isBubbleless {
                textColor = theme.chat.serviceMessage.dateTextColor.withoutWallpaper
                fillColor = textColor.withMultipliedAlpha(0.12)
            } else {
                textColor = serviceMessageColorComponents(theme: theme, wallpaper: wallpaper).primaryText
                fillColor = selectDateFillStaticColor(theme: theme, wallpaper: wallpaper)
            }

            let kind = item.data.kind
            let horizontalPadding: CGFloat = 10.0
            let verticalPadding: CGFloat = kind == .trialLabel ? 2.0 : 4.0
            let maxContentWidth = max(40.0, params.width - params.leftInset - params.rightInset - 32.0 - horizontalPadding * 2.0)

            let mainText: String
            let mainFont: UIFont
            var maxLines = 1
            switch kind {
            case .folded:
                mainText = LuminaAdShieldFoldTexts.foldRow(item.data)
                mainFont = luminaAdShieldRowFont
                maxLines = 3
            case .expandedHeader:
                mainText = LuminaAdShieldFoldTexts.headerTitle
                mainFont = luminaAdShieldRowFont
            case .trialLabel:
                mainText = LuminaAdShieldFoldTexts.trialLabel
                mainFont = luminaAdShieldLabelFont
            }

            func textArguments(_ string: String, _ font: UIFont, maxWidth: CGFloat, lines: Int, alignment: NSTextAlignment) -> TextNodeLayoutArguments {
                return TextNodeLayoutArguments(attributedString: NSAttributedString(string: string, font: font, textColor: textColor), backgroundColor: nil, maximumNumberOfLines: lines, truncationType: .end, constrainedSize: CGSize(width: maxWidth, height: CGFloat.greatestFiniteMagnitude), alignment: alignment, cutout: nil, insets: UIEdgeInsets())
            }

            // Header: 「重複訊息（疑似廣告）· 收合 · 不是廣告」 on one line; the actions keep their width, the title truncates.
            var actions: (leadingSeparator: (TextNodeLayout, () -> TextNode), fold: (TextNodeLayout, () -> TextNode), separator: (TextNodeLayout, () -> TextNode), notAd: (TextNodeLayout, () -> TextNode))?
            var actionsWidth: CGFloat = 0.0
            if kind == .expandedHeader {
                let leadingSeparator = makeLeadingSeparatorLayout(textArguments(" · ", luminaAdShieldRowFont, maxWidth: maxContentWidth, lines: 1, alignment: .natural))
                let fold = makeFoldLayout(textArguments(LuminaAdShieldFoldTexts.fold, luminaAdShieldActionFont, maxWidth: maxContentWidth, lines: 1, alignment: .natural))
                let separator = makeSeparatorLayout(textArguments(" · ", luminaAdShieldRowFont, maxWidth: maxContentWidth, lines: 1, alignment: .natural))
                let notAd = makeNotAdLayout(textArguments(LuminaAdShieldFoldTexts.notAd, luminaAdShieldActionFont, maxWidth: maxContentWidth, lines: 1, alignment: .natural))
                actions = (leadingSeparator, fold, separator, notAd)
                actionsWidth = leadingSeparator.0.size.width + fold.0.size.width + separator.0.size.width + notAd.0.size.width
            }

            let mainLayout = makeTextLayout(textArguments(mainText, mainFont, maxWidth: max(20.0, maxContentWidth - actionsWidth), lines: maxLines, alignment: .center))

            var contentWidth = mainLayout.0.size.width
            var contentHeight = mainLayout.0.size.height
            if let actions {
                contentWidth += actionsWidth
                contentHeight = max(contentHeight, max(actions.fold.0.size.height, actions.notAd.0.size.height))
            }
            let pillSize = CGSize(width: ceil(contentWidth) + horizontalPadding * 2.0, height: ceil(contentHeight) + verticalPadding * 2.0)

            // A header or trial label sits right on top of its message; a fold row is spaced like the unread bar.
            let dateInset = dateAtBottom ? layoutConstants.timestampHeaderHeight : 0.0
            let insets: UIEdgeInsets
            switch kind {
            case .folded:
                insets = UIEdgeInsets(top: 6.0 + dateInset, left: 0.0, bottom: 5.0, right: 0.0)
            case .expandedHeader, .trialLabel:
                insets = UIEdgeInsets(top: 6.0 + dateInset, left: 0.0, bottom: 1.0, right: 0.0)
            }
            let layout = ListViewItemNodeLayout(contentSize: CGSize(width: params.width, height: pillSize.height), insets: insets)

            return (layout, { animation in
                guard let self else {
                    return
                }
                self.item = item

                let _ = mainLayout.1()
                let pillFrame = CGRect(origin: CGPoint(x: params.leftInset + floorToScreenPixels((params.width - params.leftInset - params.rightInset - pillSize.width) / 2.0), y: 0.0), size: pillSize)
                self.backgroundNode.backgroundColor = fillColor
                self.backgroundNode.cornerRadius = min(pillSize.height / 2.0, 12.0)
                animation.animator.updateFrame(layer: self.backgroundNode.layer, frame: pillFrame, completion: nil)

                func centered(_ size: CGSize, x: CGFloat) -> CGRect {
                    return CGRect(origin: CGPoint(x: x, y: pillFrame.minY + floorToScreenPixels((pillSize.height - size.height) / 2.0)), size: size)
                }

                self.pillFrame = pillFrame
                var x = pillFrame.minX + horizontalPadding
                let mainFrame = centered(mainLayout.0.size, x: x)
                animation.animator.updateFrame(layer: self.textNode.layer, frame: mainFrame, completion: nil)
                x += mainLayout.0.size.width
                var foldFrame = CGRect()
                var notAdFrame = CGRect()

                self.foldTapFrame = nil
                self.notAdTapFrame = nil
                let actionNodes: [ASDisplayNode] = [self.leadingSeparatorNode, self.foldNode, self.separatorNode, self.notAdNode]
                if let actions {
                    let _ = actions.leadingSeparator.1()
                    let _ = actions.fold.1()
                    let _ = actions.separator.1()
                    let _ = actions.notAd.1()
                    for node in actionNodes {
                        node.isHidden = false
                    }
                    let leadingSeparatorFrame = centered(actions.leadingSeparator.0.size, x: x)
                    x += leadingSeparatorFrame.width
                    foldFrame = centered(actions.fold.0.size, x: x)
                    x += foldFrame.width
                    let separatorFrame = centered(actions.separator.0.size, x: x)
                    x += separatorFrame.width
                    notAdFrame = centered(actions.notAd.0.size, x: x)
                    self.leadingSeparatorNode.frame = leadingSeparatorFrame
                    self.foldNode.frame = foldFrame
                    self.separatorNode.frame = separatorFrame
                    self.notAdNode.frame = notAdFrame

                    // Generous tap targets: taller than the pill, and half of each neighbouring separator.
                    self.foldTapFrame = CGRect(x: foldFrame.minX - leadingSeparatorFrame.width / 2.0, y: pillFrame.minY - 8.0, width: foldFrame.width + leadingSeparatorFrame.width / 2.0 + separatorFrame.width / 2.0, height: pillFrame.height + 16.0)
                    self.notAdTapFrame = CGRect(x: notAdFrame.minX - separatorFrame.width / 2.0, y: pillFrame.minY - 8.0, width: notAdFrame.width + separatorFrame.width / 2.0 + horizontalPadding, height: pillFrame.height + 16.0)
                } else {
                    for node in actionNodes {
                        node.isHidden = true
                    }
                }

                self.updateAccessibility(item: item, pillFrame: pillFrame, mainFrame: mainFrame, foldFrame: foldFrame, notAdFrame: notAdFrame)
            })
        }
    }

    private func updateAccessibility(item: LuminaAdShieldFoldItem, pillFrame: CGRect, mainFrame: CGRect, foldFrame: CGRect, notAdFrame: CGRect) {
        let data = item.data
        switch data.kind {
        case .folded:
            self.mainArea.isAccessibilityElement = true
            self.mainArea.frame = pillFrame
            self.mainArea.accessibilityLabel = LuminaAdShieldFoldTexts.foldRow(data)
            self.mainArea.accessibilityHint = LuminaAdShieldFoldTexts.showHint
            self.mainArea.accessibilityTraits = .button
            self.mainArea.activate = { [weak self] in
                guard let self, let item = self.item else {
                    return false
                }
                item.interaction?.show(item.data)
                return true
            }
            self.mainArea.accessibilityCustomActions = [
                UIAccessibilityCustomAction(name: LuminaAdShieldFoldTexts.notAd, actionHandler: { [weak self] _ in
                    guard let self, let item = self.item else {
                        return false
                    }
                    item.interaction?.notAd(item.data)
                    return true
                }),
                UIAccessibilityCustomAction(name: LuminaAdShieldTexts.modeLabel(.off, globalOn: false), actionHandler: { [weak self] _ in
                    guard let self, let item = self.item else {
                        return false
                    }
                    item.interaction?.turnOffInThisGroup()
                    return true
                })
            ]
            self.foldArea.isAccessibilityElement = false
            self.notAdArea.isAccessibilityElement = false
        case .expandedHeader:
            self.mainArea.isAccessibilityElement = true
            self.mainArea.frame = mainFrame
            self.mainArea.accessibilityLabel = LuminaAdShieldFoldTexts.headerTitle
            self.mainArea.accessibilityHint = nil
            self.mainArea.accessibilityTraits = .header
            self.mainArea.activate = nil
            self.mainArea.accessibilityCustomActions = nil

            self.foldArea.isAccessibilityElement = true
            self.foldArea.frame = foldFrame
            self.foldArea.accessibilityLabel = LuminaAdShieldFoldTexts.fold
            self.foldArea.accessibilityTraits = .button
            self.foldArea.activate = { [weak self] in
                guard let self, let item = self.item else {
                    return false
                }
                item.interaction?.fold(item.data)
                return true
            }
            self.notAdArea.isAccessibilityElement = true
            self.notAdArea.frame = notAdFrame
            self.notAdArea.accessibilityLabel = LuminaAdShieldFoldTexts.notAd
            self.notAdArea.accessibilityTraits = .button
            self.notAdArea.activate = { [weak self] in
                guard let self, let item = self.item else {
                    return false
                }
                item.interaction?.notAd(item.data)
                return true
            }
        case .trialLabel:
            self.mainArea.isAccessibilityElement = true
            self.mainArea.frame = pillFrame
            self.mainArea.accessibilityLabel = LuminaAdShieldFoldTexts.trialLabel
            self.mainArea.accessibilityHint = nil
            self.mainArea.accessibilityTraits = .staticText
            self.mainArea.activate = nil
            self.mainArea.accessibilityCustomActions = nil
            self.foldArea.isAccessibilityElement = false
            self.notAdArea.isAccessibilityElement = false
        }
    }

    // MARK: Gestures

    private func gestureShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let item = self.item else {
            return false
        }
        let location = gestureRecognizer.location(in: self.view)
        switch item.data.kind {
        case .folded:
            return self.pillFrame.insetBy(dx: -4.0, dy: -8.0).contains(location)
        case .expandedHeader:
            if gestureRecognizer is UILongPressGestureRecognizer {
                return false
            }
            if let foldTapFrame = self.foldTapFrame, foldTapFrame.contains(location) {
                return true
            }
            if let notAdTapFrame = self.notAdTapFrame, notAdTapFrame.contains(location) {
                return true
            }
            return false
        case .trialLabel:
            return false
        }
    }

    @objc private func tapGesture(_ recognizer: UITapGestureRecognizer) {
        guard recognizer.state == .ended, let item = self.item else {
            return
        }
        let location = recognizer.location(in: self.view)
        switch item.data.kind {
        case .folded:
            item.interaction?.show(item.data)
        case .expandedHeader:
            if let foldTapFrame = self.foldTapFrame, foldTapFrame.contains(location) {
                self.foldNode.layer.animateAlpha(from: 0.4, to: 1.0, duration: 0.25)
                item.interaction?.fold(item.data)
            } else if let notAdTapFrame = self.notAdTapFrame, notAdTapFrame.contains(location) {
                self.notAdNode.layer.animateAlpha(from: 0.4, to: 1.0, duration: 0.25)
                item.interaction?.notAd(item.data)
            }
        case .trialLabel:
            break
        }
    }

    @objc private func longPressGesture(_ recognizer: UILongPressGestureRecognizer) {
        if recognizer.state == .began {
            self.openMenu()
        }
    }

    @objc private func secondaryClickGesture(_ recognizer: UITapGestureRecognizer) {
        if recognizer.state == .ended {
            self.openMenu()
        }
    }

    private func openMenu() {
        guard let item = self.item, item.data.kind == .folded, self.isNodeLoaded else {
            return
        }
        item.interaction?.openMenu(item.data, sourceView: self.backgroundNode.view)
    }
}
