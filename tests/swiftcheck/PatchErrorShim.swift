// Same cases as PatchError in ios/TikTokHD/Patcher.swift, without AVFoundation.
enum PatchError: Error {
    case damaged(String)
    case export(String)
    case changed(String)
}
