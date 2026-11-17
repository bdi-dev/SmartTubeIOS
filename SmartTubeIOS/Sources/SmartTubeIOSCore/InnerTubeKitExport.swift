// The stream extractor (InnerTube API, client profiles, PoToken, HLS manifest parsing and
// the models they return) lives in the `InnerTubeKit` target. It is re-exported here so
// every existing `import SmartTubeIOSCore` keeps seeing those types unchanged.
@_exported import InnerTubeKit
