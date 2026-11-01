import Photos
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// Patched videos live in the app's Documents folder, which the Files app
/// shows as On My iPhone > TikTok HD (UIFileSharingEnabled).
enum Store {
    static var folder: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    static func list() -> [URL] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return urls.filter { $0.pathExtension.lowercased() == "mp4" && !$0.lastPathComponent.hasPrefix(".") }
            .sorted { modified($0) > modified($1) }
    }

    private static func modified(_ u: URL) -> Date {
        (try? u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }

    static func output(for name: String) -> URL {
        let stem = name.components(separatedBy: CharacterSet.alphanumerics.union(.init(charactersIn: " -_")).inverted)
            .joined().trimmingCharacters(in: .whitespaces)
        let f = DateFormatter()
        f.dateFormat = "HHmmss"
        return folder.appendingPathComponent("\(stem.isEmpty ? "video" : String(stem.prefix(40)))-\(f.string(from: Date()))_patched.mp4")
    }
}

@MainActor
final class PatchModel: ObservableObject {
    @Published var busy = false
    @Published var step = ""
    @Published var error: String?
    @Published var result: (before: VideoInfo, after: VideoInfo, file: URL)?
    @Published var files: [URL] = Store.list()

    func patch(_ src: URL, name: String) {
        busy = true
        error = nil
        result = nil
        step = "Starting…"
        let dst = Store.output(for: (name as NSString).deletingPathExtension)
        Task {
            do {
                let (a, b) = try await Patcher.run(src: src, dst: dst) { s in
                    Task { @MainActor in self.step = s }
                }
                result = (a, b, dst)
            } catch {
                self.error = error.localizedDescription
            }
            try? FileManager.default.removeItem(at: src)
            busy = false
            files = Store.list()
        }
    }

    func delete(_ u: URL) {
        try? FileManager.default.removeItem(at: u)
        if result?.file == u { result = nil }
        files = Store.list()
    }
}

struct PatchView: View {
    /// Opens TikTok Studio and puts this video in its upload box.
    var openStudio: (URL?) -> Void
    @StateObject private var model = PatchModel()
    @State private var showPhotos = false
    @State private var showFiles = false
    @State private var share: URL?
    @State private var exportFile: URL?
    @State private var saveNote: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button { showPhotos = true } label: {
                        Label("Choose from Photos", systemImage: "photo.on.rectangle")
                    }
                    Button { showFiles = true } label: {
                        Label("Choose from Files", systemImage: "folder")
                    }
                } header: {
                    Text("1 · Patch a video")
                } footer: {
                    Text("Keeps 4K, 60 fps, HDR and Dolby Vision. Nothing is re-encoded.")
                }
                .disabled(model.busy)

                if model.busy {
                    Section { HStack(spacing: 12) { ProgressView(); Text(model.step) } }
                }
                if let e = model.error {
                    Section { Label(e, systemImage: "xmark.octagon").foregroundStyle(.red) }
                }
                if let r = model.result {
                    Section {
                        Label("Patched. Same frames, fps and HDR as your original.", systemImage: "checkmark.seal.fill")
                            .foregroundStyle(.green)
                        compare("Size", r.before.sizeText, r.after.sizeText)
                        compare("Frame rate", "\(r.before.fps) fps", "\(r.after.fps) fps")
                        compare("HDR", r.before.hdrText, r.after.hdrText)
                        compare("Frames", "\(r.before.frames)", "\(r.after.frames)")
                        compare("Codec", r.before.codec, r.after.codec)
                        compare("Quality", "\(r.before.mbps) Mbps", "\(r.after.mbps) Mbps")
                        compare("File", "\(r.before.megabytes) MB", "\(r.after.megabytes) MB")
                    } header: {
                        Text("Original → patched")
                    }
                    Section {
                        Button { exportFile = r.file } label: { Label("Save to Files…", systemImage: "folder.badge.plus") }
                        Button { saveToPhotos(r.file) } label: { Label("Save to Photos", systemImage: "photo.badge.plus") }
                        Button { share = r.file } label: { Label("Share / AirDrop…", systemImage: "square.and.arrow.up") }
                        if let n = saveNote { Text(n).font(.footnote).foregroundStyle(.secondary) }
                    } header: {
                        Text("2 · Save")
                    } footer: {
                        Text("It's also kept in Files → On My iPhone → TikTok HD.")
                    }
                    Section {
                        Button { openStudio(r.file) } label: {
                            Label("Upload in TikTok Studio", systemImage: "arrow.up.circle.fill").bold()
                        }
                    } header: {
                        Text("3 · Upload")
                    } footer: {
                        Text("Opens TikTok Studio and puts \(r.file.lastPathComponent) in its upload box by itself. If it can't, tap Select video → Choose File → Browse → On My iPhone → TikTok HD. Don't pick it from Photos (iOS would compress it). Don't trim it in TikTok. First time, post as Only me to check.")
                    }
                }

                if !model.files.isEmpty {
                    Section("Patched videos") {
                        ForEach(model.files, id: \.self) { u in
                            Menu {
                                Button { openStudio(u) } label: { Label("Upload in TikTok Studio", systemImage: "arrow.up.circle") }
                                Button { exportFile = u } label: { Label("Save to Files…", systemImage: "folder.badge.plus") }
                                Button { saveToPhotos(u) } label: { Label("Save to Photos", systemImage: "photo.badge.plus") }
                                Button { share = u } label: { Label("Share / AirDrop…", systemImage: "square.and.arrow.up") }
                                Button(role: .destructive) { model.delete(u) } label: { Label("Delete", systemImage: "trash") }
                            } label: {
                                Text(u.lastPathComponent).font(.footnote).foregroundStyle(.primary)
                            }
                            .swipeActions {
                                Button(role: .destructive) { model.delete(u) } label: { Label("Delete", systemImage: "trash") }
                            }
                        }
                    }
                }
            }
            .navigationTitle("TikTok HD")
        }
        .sheet(isPresented: $showPhotos) {
            PhotoPicker { url, name in
                showPhotos = false
                if let url { model.patch(url, name: name) }
            }
            .ignoresSafeArea()
        }
        .fileImporter(isPresented: $showFiles, allowedContentTypes: [.movie, .mpeg4Movie, .quickTimeMovie]) { res in
            guard case .success(let url) = res else { return }
            // Copy it in: the picked file is only readable for a moment.
            let ok = url.startAccessingSecurityScopedResource()
            defer { if ok { url.stopAccessingSecurityScopedResource() } }
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "." + url.pathExtension)
            do {
                try FileManager.default.copyItem(at: url, to: tmp)
                model.patch(tmp, name: url.lastPathComponent)
            } catch {
                model.error = error.localizedDescription
            }
        }
        .sheet(item: $share) { u in ShareSheet(items: [u]) }
        .sheet(item: $exportFile) { u in FileExporter(url: u).ignoresSafeArea() }
    }

    /// Adds the file to Photos as it is (no conversion). For uploading, pick it
    /// from Files, not Photos: Safari-style pickers compress Photos videos.
    private func saveToPhotos(_ u: URL) {
        saveNote = "Saving to Photos…"
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else {
                DispatchQueue.main.async { saveNote = "Allow Photos in Settings → TikTok HD → Photos." }
                return
            }
            PHPhotoLibrary.shared().performChanges({
                let opts = PHAssetResourceCreationOptions()
                opts.shouldMoveFile = false
                opts.originalFilename = u.lastPathComponent
                PHAssetCreationRequest.forAsset().addResource(with: .video, fileURL: u, options: opts)
            }) { ok, err in
                DispatchQueue.main.async {
                    saveNote = ok ? "Saved to Photos (\(u.lastPathComponent))."
                        : "Photos didn't take it: \(err?.localizedDescription ?? "unknown error"). Use Save to Files."
                }
            }
        }
    }

    private func compare(_ k: String, _ a: String, _ b: String) -> some View {
        HStack {
            Text(k).foregroundStyle(.secondary).frame(width: 90, alignment: .leading)
            Text(a).frame(maxWidth: .infinity, alignment: .leading)
            Text(b).frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.subheadline)
    }
}

extension URL: @retroactive Identifiable { public var id: String { absoluteString } }

/// Photos picker that hands over the ORIGINAL file (no HEVC→H.264 conversion).
struct PhotoPicker: UIViewControllerRepresentable {
    var done: (URL?, String) -> Void

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var cfg = PHPickerConfiguration(photoLibrary: .shared())
        cfg.filter = .videos
        cfg.selectionLimit = 1
        cfg.preferredAssetRepresentationMode = .current
        let vc = PHPickerViewController(configuration: cfg)
        vc.delegate = context.coordinator
        return vc
    }

    func updateUIViewController(_ vc: PHPickerViewController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(done: done) }

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let done: (URL?, String) -> Void
        init(done: @escaping (URL?, String) -> Void) { self.done = done }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            guard let item = results.first?.itemProvider,
                  let type = item.registeredTypeIdentifiers.first(where: { UTType($0)?.conforms(to: .movie) == true })
            else {
                done(nil, "")
                return
            }
            let name = item.suggestedName ?? "video"
            item.loadFileRepresentation(forTypeIdentifier: type) { url, _ in
                // The given file is deleted when this returns: copy it now.
                var copy: URL?
                if let url {
                    let tmp = FileManager.default.temporaryDirectory
                        .appendingPathComponent(UUID().uuidString + "." + url.pathExtension)
                    if (try? FileManager.default.copyItem(at: url, to: tmp)) != nil { copy = tmp }
                }
                DispatchQueue.main.async { self.done(copy, name) }
            }
        }
    }
}

/// "Save to Files…": the system's export picker (copies the file anywhere in Files / iCloud Drive).
struct FileExporter: UIViewControllerRepresentable {
    var url: URL
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        UIDocumentPickerViewController(forExporting: [url], asCopy: true)
    }
    func updateUIViewController(_ vc: UIDocumentPickerViewController, context: Context) {}
}

struct ShareSheet: UIViewControllerRepresentable {
    var items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}
