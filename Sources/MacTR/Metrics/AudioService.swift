// AudioService.swift — "is the system playing audio right now?"
//
// Uses CoreAudio's kAudioDevicePropertyDeviceIsRunningSomewhere on the default
// output device: true whenever ANY process is actively feeding the output
// (Music, Spotify, a browser tab, a game …). No metadata, no entitlement, no
// permission prompt — just a boolean "sound is coming out", which is all the
// operator's dance + the foot-level spectrum need.

import CoreAudio
import Foundation

enum AudioService {
    static func isPlaying() -> Bool {
        var deviceID = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var st = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &deviceID)
        guard st == noErr, deviceID != 0 else { return false }

        var running = UInt32(0)
        size = UInt32(MemoryLayout<UInt32>.size)
        addr.mSelector = kAudioDevicePropertyDeviceIsRunningSomewhere
        st = AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, &running)
        return st == noErr && running != 0
    }
}
