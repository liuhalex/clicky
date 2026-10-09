//
//  ConversationTranscriptPanelManager.swift
//  leanring-buddy
//
//  A small scrollable window with the conversation so far (the user's
//  questions and what Clicky said), opened from the "Transcript" button in
//  the menu bar panel. Captions show only the line Clicky is saying right now;
//  this is where the full history lives, only when the user asks for it.
//
//  The newest HeyClicky writes everything into the notch as one transcript
//  that keeps growing on screen. Keeping the history behind a button keeps
//  the screen clear.
//

import AppKit
import SwiftUI

@MainActor
final class ConversationTranscriptPanelManager {
    private let companionManager: CompanionManager
    private var conversationTranscriptPanel: NSPanel?
    /// Closes the transcript when the user clicks anywhere outside Clicky.
    private var clickOutsideMonitor: Any?

    private static let transcriptWidth: CGFloat = 420
    private static let transcriptHeight: CGFloat = 360

    init(companionManager: CompanionManager) {
        self.companionManager = companionManager
    }

    var isShowingTranscript: Bool {
        conversationTranscriptPanel?.isVisible == true
    }

    func showTranscript() {
        if conversationTranscriptPanel == nil {
            createPanel()
        }
        guard let conversationTranscriptPanel else { return }

        // Top right of the screen the user is on, under the menu bar, near
        // where the menu bar panel opens
        let mouseLocation = NSEvent.mouseLocation
        let screenVisibleFrame = (NSScreen.screens.first { $0.frame.contains(mouseLocation) } ?? NSScreen.main)?.visibleFrame
            ?? .zero
        conversationTranscriptPanel.setFrame(
            NSRect(
                x: screenVisibleFrame.maxX - Self.transcriptWidth - 16,
                y: screenVisibleFrame.maxY - Self.transcriptHeight - 8,
                width: Self.transcriptWidth,
                height: Self.transcriptHeight
            ),
            display: true
        )
        conversationTranscriptPanel.orderFrontRegardless()
        installClickOutsideMonitor()
    }

    func hideTranscript() {
        conversationTranscriptPanel?.orderOut(nil)
        if let clickOutsideMonitor {
            NSEvent.removeMonitor(clickOutsideMonitor)
            self.clickOutsideMonitor = nil
        }
    }

    private func createPanel() {
        let transcriptView = ConversationTranscriptView(
            companionManager: companionManager,
            onClose: { [weak self] in self?.hideTranscript() }
        )
        let hostingView = NSHostingView(rootView: transcriptView)
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = .clear

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.transcriptWidth, height: Self.transcriptHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isExcludedFromWindowsMenu = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = false
        panel.contentView = hostingView
        conversationTranscriptPanel = panel
    }

    private func installClickOutsideMonitor() {
        guard clickOutsideMonitor == nil else { return }
        // Global monitors only see clicks in other apps, which is exactly
        // "outside the transcript" (clicks in Clicky's own panel don't close it)
        clickOutsideMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.hideTranscript()
            }
        }
    }
}

// MARK: - View

private struct ConversationTranscriptView: View {
    @ObservedObject var companionManager: CompanionManager
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("transcript")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white.opacity(0.6))
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(.white.opacity(0.7))
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { isHovering in
                    if isHovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 8)

            ScrollViewReader { scrollProxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        if companionManager.conversationTranscriptEntries.isEmpty {
                            Text("nothing said yet")
                                .font(.system(size: 13))
                                .foregroundColor(.white.opacity(0.5))
                        }
                        ForEach(companionManager.conversationTranscriptEntries) { transcriptEntry in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(transcriptEntry.speaker == .user ? "you" : "clicky")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundColor(transcriptEntry.speaker == .user
                                        ? .white.opacity(0.45)
                                        : DS.Colors.overlayCursorBlue)
                                Text(transcriptEntry.text)
                                    .font(.system(size: 13))
                                    .foregroundColor(.white.opacity(transcriptEntry.speaker == .user ? 0.75 : 0.95))
                                    .textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .id(transcriptEntry.id)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                }
                .onAppear {
                    if let newestTranscriptEntry = companionManager.conversationTranscriptEntries.last {
                        scrollProxy.scrollTo(newestTranscriptEntry.id, anchor: .bottom)
                    }
                }
                .onChange(of: companionManager.conversationTranscriptEntries.count) { _, _ in
                    if let newestTranscriptEntry = companionManager.conversationTranscriptEntries.last {
                        withAnimation { scrollProxy.scrollTo(newestTranscriptEntry.id, anchor: .bottom) }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.black.opacity(0.9))
        )
    }
}
