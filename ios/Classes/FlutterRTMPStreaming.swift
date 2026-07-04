import Flutter
import UIKit
import AVFoundation
import Accelerate
import CoreMotion
import HaishinKit
import os
import ReplayKit
import VideoToolbox

@objc
public class FlutterRTMPStreaming : NSObject {
    private var rtmpConnection = RTMPConnection()
    private var rtmpStream: RTMPStream!
    private var url: String? = nil
    private var name: String? = nil
    private var retries: Int = 0
    private let eventSink: FlutterEventSink
    private let myDelegate = MyRTMPStreamQoSDelagate()
    private var orientationObserver: NSObjectProtocol?
    private var streamWidth: Int = 0
    private var streamHeight: Int = 0

    @objc
    public init(sink: @escaping FlutterEventSink) {
        eventSink = sink
        // Start device orientation notifications at construction so that
        // UIDevice.current.orientation returns accurate values by the time
        // open() runs, rather than .unknown on the first call.
        UIDevice.current.beginGeneratingDeviceOrientationNotifications()
    }

    /// Returns the current device orientation from the accelerometer.
    /// Uses UIDevice.current.orientation (physical orientation) rather than
    /// UIInterfaceOrientation because Flutter's SystemChrome.setPreferredOrientations
    /// doesn't always rotate the iOS window scene — so windowScene.interfaceOrientation
    /// can report .portrait even when the phone is held landscape. The physical
    /// device orientation always reflects how the phone is actually held.
    private func currentDeviceOrientation() -> AVCaptureVideoOrientation? {
        let device = UIDevice.current
        if !device.isGeneratingDeviceOrientationNotifications {
            device.beginGeneratingDeviceOrientationNotifications()
        }
        if let orientation = DeviceUtil.videoOrientation(by: device.orientation) {
            return orientation
        }
        // Fallback when the accelerometer hasn't settled yet (e.g. .unknown
        // or .faceUp/.faceDown). The window scene orientation lags the
        // physical orientation in Flutter apps but is at least never .unknown.
        if #available(iOS 13.0, *),
           let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene {
            return DeviceUtil.videoOrientation(by: scene.interfaceOrientation)
        }
        return DeviceUtil.videoOrientation(by: UIApplication.shared.statusBarOrientation)
    }

    /// Configures the RTMP encoder to produce an upright video.
    ///
    /// The camera capture connection is hardcoded to `.portrait` in
    /// `RtmppublisherPlugin.m`, so the buffers that reach
    /// `addVideoDataWithBuffer:` are already 480x640 portrait frames with
    /// content oriented for portrait viewing. The RTMPStream's internal
    /// `output.connections.videoOrientation` does NOT apply a physical
    /// rotation to externally-fed buffers — it only affects the H.264
    /// display matrix. So to produce an upright video we must:
    ///
    /// 1. Set encoder dimensions to match the portrait input (480x640)
    /// 2. Set rtmpStream.orientation to .portrait (no display rotation)
    ///
    /// The resulting stream is a portrait video (tall) with upright
    /// content. In a landscape browser player it will be letterboxed
    /// with black bars on the sides — not rotated.
    private func applyCurrentOrientation() {
        self.rtmpStream.orientation = .portrait
        self.rtmpStream.videoSettings[.width] = self.streamHeight
        self.rtmpStream.videoSettings[.height] = self.streamWidth
        print("Orient .portrait (fixed), dims \(self.streamHeight)x\(self.streamWidth)")
    }

    @objc
    public func open(url: String, width: Int, height: Int, bitrate: Int) {
        rtmpStream = RTMPStream(connection: rtmpConnection)
        rtmpStream.captureSettings = [
            .sessionPreset: AVCaptureSession.Preset.hd1280x720,
            .continuousAutofocus: true,
            .continuousExposure: true
        ]
        rtmpConnection.addEventListener(.rtmpStatus, selector:#selector(rtmpStatusHandler), observer: self)
        rtmpConnection.addEventListener(.ioError, selector: #selector(rtmpErrorHandler), observer: self)

        let uri = URL(string: url)
        self.name = uri?.pathComponents.last
        var bits = url.components(separatedBy: "/")
        bits.removeLast()
        self.url = bits.joined(separator: "/")

        // TODO: Da correggere
        rtmpStream.videoSettings = [
            .width: width,
            .height: height,
            .profileLevel: kVTProfileLevel_H264_Baseline_AutoLevel,
            .maxKeyFrameIntervalDuration: 2,
            .bitrate: bitrate
        ]
        rtmpStream.captureSettings = [
            .fps: 30
        ]
        rtmpStream.delegate = myDelegate
        self.retries = 0
        self.streamWidth = width
        self.streamHeight = height
        // Run this on the ui thread.
        DispatchQueue.main.async {
            // Ensure device orientation notifications are running so the
            // first read of UIDevice.current.orientation is accurate.
            UIDevice.current.beginGeneratingDeviceOrientationNotifications()

            // Subscribe before applying so the first orientation-change
            // notification (which fires when notifications are first
            // enabled on iOS) is captured.
            self.orientationObserver = NotificationCenter.default.addObserver(
                forName: UIDevice.orientationDidChangeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.applyCurrentOrientation()
            }

            self.applyCurrentOrientation()

            self.rtmpConnection.connect(self.url ?? "frog")
        }
    }
    
    @objc
    private func rtmpStatusHandler(_ notification: Notification) {
        let e = Event.from(notification)
        guard let data: ASObject = e.data as? ASObject, let code: String = data["code"] as? String else {
            return
        }
        print(e)
        
        switch code {
        case RTMPConnection.Code.connectSuccess.rawValue:
            rtmpStream.publish(name)
            retries = 0
            break
        case RTMPConnection.Code.connectFailed.rawValue, RTMPConnection.Code.connectClosed.rawValue:
            guard retries <= 3 else {
                eventSink(["event" : "error",
                           "errorDescription" : "connection failed " + e.type.rawValue])
                return
            }
            retries += 1
            Thread.sleep(forTimeInterval: pow(2.0, Double(retries)))
            rtmpConnection.connect(url!)
            eventSink(["event" : "rtmp_retry",
                       "errorDescription" : "connection failed " + e.type.rawValue])
            break
        default:
            break
        }
    }
    
    @objc
    private func rtmpErrorHandler(_ notification: Notification) {
        if #available(iOS 10.0, *) {
            os_log("%s", notification.name.rawValue)
        }
        guard retries <= 3 else {
            eventSink(["event" : "rtmp_stopped",
                       "errorDescription" : "rtmp disconnected"])
            return
        }
        retries+=1
        Thread.sleep(forTimeInterval: pow(2.0, Double(retries)))
        rtmpConnection.connect(url!)
        eventSink(["event" : "rtmp_retry",
                   "errorDescription" : "rtmp disconnected"])
        
    }
    
    @objc
    public func pauseVideoStreaming() {
        rtmpStream.paused = true
    }
    
    @objc
    public func resumeVideoStreaming() {
        rtmpStream.paused = false
    }
    
    @objc
    public func isPaused() -> Bool{
        return rtmpStream.paused
    }
    
    
    @objc
    public func getStreamStatistics() -> NSDictionary {
        let ret: NSDictionary = [
            "paused": isPaused(),
            "bitrate": rtmpStream.videoSettings[.bitrate]!,
            "width": rtmpStream.videoSettings[.width]!,
            "height": rtmpStream.videoSettings[.height]!,
            "fps": (rtmpStream.captureSettings[.fps]! as! NSNumber).floatValue,
            "orientation": rtmpStream.orientation.rawValue
        ]
        //ret["cacheSize"] = rtmpConnection.bandWidth
        //ret["sentAudioFrames"] = rtmpCamera!!.sentAudioFrames
        //        ret["sentVideoFrames"] = rtmpCamera!!.sentVideoFrames
        //if (rtmpCamera!!.droppedAudioFrames == null) {
        //ret["droppedAudioFrames"] = 0
        //} else {
        //ret["droppedAudioFrames"] = rtmpCamera!!.droppedAudioFrames
        //}
        //ret["droppedVideoFrames"] = rtmpCamera!!.droppedVideoFrames
        //ret["isAudioMuted"] = rtmpCamera!!.isAudioMuted
        return ret
    }
    
    @objc
    public func addVideoData(buffer: CMSampleBuffer) {
        if let description = CMSampleBufferGetFormatDescription(buffer) {
            let dimensions = CMVideoFormatDescriptionGetDimensions(description)
            rtmpStream.videoSettings = [
                .width: dimensions.width,
                .height: dimensions.height,
                .profileLevel: kVTProfileLevel_H264_Baseline_AutoLevel,
                .maxKeyFrameIntervalDuration: 2,
                .bitrate: 1200 * 1024
            ]
            rtmpStream.captureSettings = [
                .fps: 24
            ]
        }
        rtmpStream.appendSampleBuffer( buffer, withType: .video)
    }
    
    @objc
    public func addAudioData(buffer: CMSampleBuffer) {
        rtmpStream.appendSampleBuffer( buffer, withType: .audio)
    }
    
    @objc
    public func close() {
        if let observer = orientationObserver {
            NotificationCenter.default.removeObserver(observer)
            orientationObserver = nil
        }
        UIDevice.current.endGeneratingDeviceOrientationNotifications()
        rtmpConnection.close()
    }
}


class MyRTMPStreamQoSDelagate: RTMPStreamDelegate {
    let minBitrate: UInt32 = 300 * 1024
    let maxBitrate: UInt32 = 2500 * 1024
    let incrementBitrate: UInt32 = 512 * 1024
    
    func didPublishSufficientBW(_ stream: RTMPStream, withConnection: RTMPConnection) {
        guard let videoBitrate = stream.videoSettings[.bitrate] as? UInt32 else { return }
        
        var newVideoBitrate = videoBitrate + incrementBitrate
        if newVideoBitrate > maxBitrate {
            newVideoBitrate = maxBitrate
        }
        print("didPublishSufficientBW update: \(videoBitrate) -> \(newVideoBitrate)")
        stream.videoSettings[.bitrate] = newVideoBitrate
    }
    
    
    // detect upload insufficent BandWidth
    func didPublishInsufficientBW(_ stream:RTMPStream, withConnection:RTMPConnection) {
        guard let videoBitrate = stream.videoSettings[.bitrate] as? UInt32 else { return }
        
        var         newVideoBitrate = UInt32(videoBitrate / 2)
        if newVideoBitrate < minBitrate {
            newVideoBitrate = minBitrate
        }
        print("didPublishInsufficientBW update: \(videoBitrate) -> \(newVideoBitrate)")
        stream.videoSettings[.bitrate] = newVideoBitrate
    }
    
    func clear() {
    }
}
