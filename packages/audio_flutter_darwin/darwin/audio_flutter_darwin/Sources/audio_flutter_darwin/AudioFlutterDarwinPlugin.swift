import Cocoa
import FlutterMacOS

public final class AudioFlutterDarwinPlugin: NSObject, FlutterPlugin {
  private let host: DarwinAudioHostApiImpl

  init(host: DarwinAudioHostApiImpl) {
    self.host = host
  }

  deinit {
    host.teardown()
  }

  public static func register(with registrar: FlutterPluginRegistrar) {
    let messenger = registrar.messenger
    let events = SessionEventsHandler()
    SessionEventsStreamHandler.register(with: messenger, streamHandler: events)
    let host = DarwinAudioHostApiImpl(events: events)
    DarwinAudioHostApiSetup.setUp(binaryMessenger: messenger, api: host)
    let plugin = AudioFlutterDarwinPlugin(host: host)

    let channel = FlutterMethodChannel(
      name: "audio_flutter_darwin/lifetime",
      binaryMessenger: messenger
    )
    registrar.addMethodCallDelegate(plugin, channel: channel)
  }

  public func handle(
    _ call: FlutterMethodCall,
    result: @escaping FlutterResult
  ) {
    result(FlutterMethodNotImplemented)
  }
}

