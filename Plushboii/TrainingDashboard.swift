import AppKit
import Charts
import Darwin
import Foundation
import IOKit.ps
import Metal
import SwiftUI

private struct TrainingMetricPoint: Identifiable, Sendable {
  let step: Int
  let value: Double

  var id: Int { step }
}

private struct TrainingDashboardSnapshot: Sendable {
  var folderPath: String? = nil
  var isDriveMounted = false
  var availableBytes: Int64?
  var trainingPID: Int32?
  var evaluationPID: Int32?
  var serverPID: Int32?
  var trainingStep: Int?
  var totalSteps: Int?
  var estimatedSecondsRemaining: Int?
  var trainingLoss: Double?
  var validationLoss: Double?
  var validationAccuracy: Double?
  var trainingSamples = 0
  var validationSamples = 0
  var datasetName: String?
  var elapsedSeconds: Int?
  var secondsPerStep: Double?
  var learningRate: Double?
  var bestLoss: Double?
  var firstLoss: Double?
  var recentAverageLoss: Double?
  var epoch: Double?
  var totalEpochs: Int?
  var logName: String?
  var logUpdatedAt: Date?
  var cpuPercent: Double?
  var residentMemoryBytes: Int64?
  var processUptime: String?
  var lastCheckpointStep: Int?
  var lastCheckpointAt: Date?
  var processDetection = "ps"
  var stepTimes: [TrainingMetricPoint] = []
  var checkpointCount = 0
  var adapterPath: String?
  var queuedPipelineStatus: String?
  var outdatedPackageCount: Int?
  var datasetCandidateCount: Int?
  var licensedDatasetCount: Int?
  var discoveryCheckedAt: String?
  var watchdogReportsPath: String?
  var automationReportMessage: String?
  var evaluationSummary: String?
  var evaluationProgress: String?
  var trainingLosses: [TrainingMetricPoint] = []
  var validationLosses: [TrainingMetricPoint] = []
  var errorMessage: String?
  var updatedAt = Date()

  var isTraining: Bool { trainingPID != nil }
  var logAge: TimeInterval? { logUpdatedAt.map { updatedAt.timeIntervalSince($0) } }
  var isLive: Bool { isTraining || (logAge.map { $0 < 90 } ?? false) }
  var estimatedFinish: Date? { estimatedSecondsRemaining.map { updatedAt.addingTimeInterval(TimeInterval($0)) } }
  var stepsPerHour: Double? { secondsPerStep.flatMap { $0 > 0 ? 3600 / $0 : nil } }
  var isEvaluating: Bool { evaluationPID != nil }
  var isBusy: Bool { isTraining || isEvaluating }
}

private struct TrainingProcess: Sendable {
  let pid: Int32
  let cpu: Double
  let rssKilobytes: Int64
  let elapsed: String
  let command: String
}

private enum TrainingStopTarget {
  case training
  case evaluation
  case server
}

private actor TrainingDashboardService {
  private var launchedProcesses: [Int32: Process] = [:]
  private var openLogHandles: [Int32: FileHandle] = [:]

  func snapshot(at root: URL) -> TrainingDashboardSnapshot {
    var result = TrainingDashboardSnapshot(folderPath: root.path)
    result.isDriveMounted = FileManager.default.fileExists(atPath: root.path)
    guard result.isDriveMounted else {
      result.errorMessage =
        "Training folder is unavailable. Reconnect the drive and choose the folder again."
      return result
    }

    var processes: [TrainingProcess] = []
    do {
      processes = try processList()
    } catch {
      result.processDetection = "pid file"
    }
    let python = root.appending(path: "venv/bin/python").path
    let trainScript = root.appending(path: "run_train.py").path
    let serverScript = root.appending(path: "run_server.py").path
    let training = processes.first {
      $0.command.contains(python) && $0.command.contains(trainScript)
    }
    let evaluation = processes.first {
      $0.command.contains(python) && $0.command.contains("/eval_cuts")
    }
    let server = processes.first {
      $0.command.contains(python) && $0.command.contains(serverScript)
    }
    result.trainingPID = training?.pid ?? (processes.isEmpty ? pidFromFile(prefix: "train", in: root) : nil)
    result.evaluationPID = evaluation?.pid
    result.serverPID = server?.pid ?? (processes.isEmpty ? pidFromFile(prefix: "server", in: root) : nil)
    if let training {
      result.cpuPercent = training.cpu
      result.residentMemoryBytes = training.rssKilobytes * 1024
      result.processUptime = training.elapsed
    }

    if let capacity = try? root.resourceValues(forKeys: [.volumeAvailableCapacityKey])
      .volumeAvailableCapacity
    {
      result.availableBytes = Int64(capacity)
    }

    let command = training?.command
    let dataset = datasetDirectory(for: command, in: root)
    result.datasetName = dataset?.lastPathComponent
    if let dataset {
      result.trainingSamples = lineCount(at: dataset.appending(path: "train.jsonl"))
      result.validationSamples = lineCount(at: dataset.appending(path: "valid.jsonl"))
    }
    if let command, let epochs = argument("--epochs", in: command).flatMap(Int.init) {
      result.totalEpochs = epochs
    }
    readAutomationReports(in: root, into: &result)

    if let logURL = trainingLog(for: command, in: root) {
      result.logName = logURL.lastPathComponent
      result.logUpdatedAt =
        (try? logURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
      parseTrainingLog(at: logURL, into: &result)
    }
    if let epochs = result.totalEpochs, let step = result.trainingStep,
      let total = result.totalSteps, total > 0
    {
      result.epoch = min(Double(epochs), Double(step) / Double(total) * Double(epochs))
    }
    if let evaluationLog = newestLog(prefix: "eval_dashboard_", in: root) {
      result.evaluationSummary = lastEvaluationSummary(at: evaluationLog)
      result.evaluationProgress = lastEvaluationProgress(at: evaluationLog)
    }

    let adapter =
      command.flatMap { argument("--output-path", in: $0) }.map { URL(fileURLWithPath: $0) }
      ?? newestAdapter(in: root)
    if let adapter, FileManager.default.fileExists(atPath: adapter.path) {
      result.adapterPath = adapter.path
      result.checkpointCount = checkpointCount(in: adapter)
      if let latest = latestCheckpoint(in: adapter) {
        result.lastCheckpointStep = latest.step
        result.lastCheckpointAt = latest.date
      }
    } else {
      result.adapterPath = newestAdapter(in: root)?.path
    }

    result.updatedAt = Date()
    return result
  }

  private func readAutomationReports(in root: URL, into snapshot: inout TrainingDashboardSnapshot) {
    let statusURL = root.appending(path: "anatomy4_pipeline.status")
    if FileManager.default.fileExists(atPath: statusURL.path) {
      do {
        let status = try String(contentsOf: statusURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        snapshot.queuedPipelineStatus = status.isEmpty ? "Empty status file" : status
      } catch {
        snapshot.queuedPipelineStatus = "Unreadable: \(error.localizedDescription)"
      }
    } else {
      snapshot.queuedPipelineStatus = "No queued pipeline status"
    }

    let reports = root.appending(path: "watchdog-reports", directoryHint: .isDirectory)
    guard FileManager.default.fileExists(atPath: reports.path) else {
      snapshot.automationReportMessage = "Watchdog report folder not found in the selected training directory."
      return
    }
    snapshot.watchdogReportsPath = reports.path

    let updatesURL = reports.appending(path: "software_updates.json")
    if FileManager.default.fileExists(atPath: updatesURL.path) {
      do {
        let report = try jsonDictionary(at: updatesURL)
        snapshot.outdatedPackageCount = (report["outdated_packages"] as? [Any])?.count
        snapshot.discoveryCheckedAt = report["checked_at"] as? String
      } catch {
        snapshot.automationReportMessage = "Software update report: \(error.localizedDescription)"
      }
    } else {
      snapshot.automationReportMessage = "The watchdog has not generated its discovery reports yet."
    }

    let datasetsURL = reports.appending(path: "training_data_candidates.json")
    if FileManager.default.fileExists(atPath: datasetsURL.path) {
      do {
        let report = try jsonDictionary(at: datasetsURL)
        guard let candidates = report["candidates"] as? [[String: Any]] else {
          throw CocoaError(.fileReadCorruptFile)
        }
        snapshot.datasetCandidateCount = candidates.count
        snapshot.licensedDatasetCount = candidates.filter { $0["license_verified"] as? Bool == true }.count
        if snapshot.discoveryCheckedAt == nil {
          snapshot.discoveryCheckedAt = report["checked_at"] as? String
        }
      } catch {
        let message = "Training-data report: \(error.localizedDescription)"
        snapshot.automationReportMessage = [snapshot.automationReportMessage, message]
          .compactMap { $0 }
          .joined(separator: " ")
      }
    } else if snapshot.automationReportMessage == nil {
      snapshot.automationReportMessage = "The watchdog has not generated its discovery reports yet."
    }
  }

  private func jsonDictionary(at url: URL) throws -> [String: Any] {
    let data = try Data(contentsOf: url)
    guard let report = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      throw CocoaError(.fileReadCorruptFile)
    }
    return report
  }

  func startTraining(at root: URL) throws {
    let processes = try processList()
    guard !isTrainingRunning(in: processes, root: root) else {
      throw DashboardError.operationAlreadyRunning("Training is already running for this folder.")
    }
    guard !isEvaluationRunning(in: processes, root: root) else {
      throw DashboardError.operationAlreadyRunning("Stop validation before starting training.")
    }
    guard
      !processes.contains(where: {
        $0.command.contains(root.appending(path: "run_server.py").path)
      })
    else {
      throw DashboardError.operationAlreadyRunning("Stop the MLX server before starting training.")
    }

    let python = root.appending(path: "venv/bin/python")
    let script = root.appending(path: "run_train.py")
    let dataset = root.appending(path: "anatomy3")
    guard FileManager.default.isExecutableFile(atPath: python.path) else {
      throw DashboardError.missingResource(
        "The training virtual environment is missing at \(python.path).")
    }
    guard FileManager.default.fileExists(atPath: script.path),
      FileManager.default.fileExists(atPath: dataset.appending(path: "train.jsonl").path),
      FileManager.default.fileExists(atPath: dataset.appending(path: "valid.jsonl").path)
    else {
      throw DashboardError.missingResource(
        "The run_train.py script or anatomy3 dataset is missing.")
    }

    let runID = UUID().uuidString.lowercased()
    let logURL = root.appending(path: "train_dashboard_\(runID).log")
    let outputURL = root.appending(path: "adapter_dashboard_\(runID)")
    try launch(
      executable: python,
      arguments: [
        script.path,
        "--model", "mlx-community/gemma-4-e4b-it-4bit",
        "--data", dataset.path,
        "--train-type", "lora",
        "--epochs", "2",
        "--learning-rate", "1e-4",
        "--lora-rank", "32",
        "--batch-size", "1",
        "--steps-per-report", "10",
        "--steps-per-eval", "100",
        "--steps-per-save", "100",
        "--val-batches", "12",
        "--grad-checkpoint",
        "--max-seq-length", "2304",
        "--train-on-completions",
        "--output-path", outputURL.path,
      ],
      workingDirectory: root,
      logURL: logURL,
      environment: trainingEnvironment(root: root)
    )
  }

  func startValidation(at root: URL) async throws {
    var processes = try processList()
    guard !isTrainingRunning(in: processes, root: root) else {
      throw DashboardError.operationAlreadyRunning(
        "Validation is disabled while training is running.")
    }
    guard !isEvaluationRunning(in: processes, root: root) else {
      throw DashboardError.operationAlreadyRunning("Validation is already running.")
    }
    guard let adapter = newestAdapter(in: root) else {
      throw DashboardError.missingResource("No adapter checkpoint was found to validate.")
    }

    let python = root.appending(path: "venv/bin/python")
    let script = root.appending(path: "eval_cuts3.py")
    guard FileManager.default.isExecutableFile(atPath: python.path),
      FileManager.default.fileExists(atPath: script.path)
    else {
      throw DashboardError.missingResource(
        "The validation environment or eval_cuts3.py script is missing.")
    }
    try await ensureServer(at: root, processes: &processes)

    let runID = UUID().uuidString.lowercased()
    let logURL = root.appending(path: "eval_dashboard_\(runID).log")
    try launch(
      executable: python,
      arguments: [script.path, adapter.path],
      workingDirectory: root,
      logURL: logURL,
      environment: trainingEnvironment(root: root)
    )
  }

  func startServer(at root: URL) async throws {
    let processes = try processList()
    let serverScript = root.appending(path: "run_server.py")
    guard !isTrainingRunning(in: processes, root: root),
      !isEvaluationRunning(in: processes, root: root)
    else {
      throw DashboardError.operationAlreadyRunning(
        "Stop training or validation before starting the MLX server.")
    }
    guard !processes.contains(where: { $0.command.contains(serverScript.path) }) else {
      throw DashboardError.operationAlreadyRunning("The MLX server is already running.")
    }
    guard
      FileManager.default.isExecutableFile(atPath: root.appending(path: "venv/bin/python").path),
      FileManager.default.fileExists(atPath: serverScript.path)
    else {
      throw DashboardError.missingResource(
        "The MLX server environment or run_server.py script is missing.")
    }

    try launch(
      executable: root.appending(path: "venv/bin/python"),
      arguments: [serverScript.path, "--host", "127.0.0.1", "--port", "8080"],
      workingDirectory: root,
      logURL: root.appending(path: "server_dashboard.log"),
      environment: trainingEnvironment(root: root)
    )
  }

  func stop(_ target: TrainingStopTarget, in root: URL) throws {
    let processes = try processList()
    let script: String
    switch target {
    case .training:
      script = root.appending(path: "run_train.py").path
    case .evaluation:
      script = root.appending(path: "eval_cuts3.py").path
    case .server:
      script = root.appending(path: "run_server.py").path
    }
    guard let process = processes.first(where: { $0.command.contains(script) }) else { return }
    guard Darwin.kill(process.pid, SIGINT) == 0 else {
      throw DashboardError.processSignalFailed(
        "Could not request a graceful stop for process \(process.pid).")
    }
  }

  private func ensureServer(at root: URL, processes: inout [TrainingProcess]) async throws {
    let healthURL = URL(string: "http://127.0.0.1:8080/health")!
    if await serverIsHealthy(at: healthURL) { return }

    let serverScript = root.appending(path: "run_server.py")
    let python = root.appending(path: "venv/bin/python")
    guard !processes.contains(where: { $0.command.contains(serverScript.path) }) else {
      throw DashboardError.serverUnavailable(
        "The MLX server process exists but its health check is failing.")
    }
    try launch(
      executable: python,
      arguments: [serverScript.path, "--host", "127.0.0.1", "--port", "8080"],
      workingDirectory: root,
      logURL: root.appending(path: "server_dashboard.log"),
      environment: trainingEnvironment(root: root)
    )

    for _ in 0..<90 {
      try await Task.sleep(for: .seconds(2))
      if await serverIsHealthy(at: healthURL) { return }
    }
    throw DashboardError.serverUnavailable(
      "The MLX server did not become healthy within three minutes. See server_dashboard.log.")
  }

  private func serverIsHealthy(at url: URL) async -> Bool {
    var request = URLRequest(url: url)
    request.timeoutInterval = 2
    do {
      let (_, response) = try await URLSession.shared.data(for: request)
      return (response as? HTTPURLResponse)?.statusCode == 200
    } catch {
      return false
    }
  }

  private func launch(
    executable: URL,
    arguments: [String],
    workingDirectory: URL,
    logURL: URL,
    environment: [String: String]
  ) throws {
    let process = Process()
    let handle = try openLog(at: logURL)
    process.executableURL = executable
    process.arguments = arguments
    process.currentDirectoryURL = workingDirectory
    process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
    process.standardOutput = handle
    process.standardError = handle
    do {
      try process.run()
      launchedProcesses[process.processIdentifier] = process
      openLogHandles[process.processIdentifier] = handle
    } catch {
      try? handle.close()
      throw error
    }
  }

  private func openLog(at url: URL) throws -> FileHandle {
    if !FileManager.default.fileExists(atPath: url.path) {
      guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
        throw DashboardError.logCreationFailed("Could not create log file at \(url.path).")
      }
    }
    let handle = try FileHandle(forWritingTo: url)
    try handle.seekToEnd()
    return handle
  }

  private func processList() throws -> [TrainingProcess] {
    let process = Process()
    let output = Pipe()
    process.executableURL = URL(fileURLWithPath: "/bin/ps")
    process.arguments = ["-axo", "pid=,%cpu=,rss=,etime=,command="]
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    try process.run()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
      throw DashboardError.processListFailed("Could not inspect local training processes.")
    }
    return String(decoding: data, as: UTF8.self)
      .split(whereSeparator: \.isNewline)
      .compactMap { line in
        let columns = line.split(
          maxSplits: 4, omittingEmptySubsequences: true, whereSeparator: \.isWhitespace)
        guard columns.count == 5, let pid = Int32(columns[0]) else { return nil }
        return TrainingProcess(
          pid: pid, cpu: Double(columns[1]) ?? 0, rssKilobytes: Int64(columns[2]) ?? 0,
          elapsed: String(columns[3]), command: String(columns[4]))
      }
  }

  private func isTrainingRunning(in processes: [TrainingProcess], root: URL) -> Bool {
    processes.contains {
      $0.command.contains(root.appending(path: "venv/bin/python").path)
        && $0.command.contains(root.appending(path: "run_train.py").path)
    }
  }

  private func isEvaluationRunning(in processes: [TrainingProcess], root: URL) -> Bool {
    processes.contains {
      $0.command.contains(root.appending(path: "venv/bin/python").path)
        && $0.command.contains(root.appending(path: "eval_cuts3.py").path)
    }
  }

  private func trainingEnvironment(root: URL) -> [String: String] {
    [
      "HF_HOME": root.appending(path: "hf").path,
      "TMPDIR": root.appending(path: "tmp").path,
    ]
  }

  private func pidFromFile(prefix: String, in root: URL) -> Int32? {
    guard
      let urls = try? FileManager.default.contentsOfDirectory(
        at: root, includingPropertiesForKeys: [.contentModificationDateKey])
    else { return nil }
    let candidates = urls.filter {
      $0.lastPathComponent.hasPrefix(prefix) && $0.pathExtension == "pid"
    }.sorted {
      let l = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
      let r = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
      return l > r
    }
    for url in candidates {
      guard let text = try? String(contentsOf: url, encoding: .utf8),
        let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines))
      else { continue }
      if kill(pid, 0) == 0 || errno == EPERM { return pid }
    }
    return nil
  }

  private func datasetDirectory(for command: String?, in root: URL) -> URL? {
    if let command, let path = argument("--data", in: command) {
      return URL(fileURLWithPath: path)
    }
    guard
      let urls = try? FileManager.default.contentsOfDirectory(
        at: root, includingPropertiesForKeys: [.contentModificationDateKey])
    else { return nil }
    return urls.filter {
      $0.lastPathComponent.hasPrefix("anatomy")
        && FileManager.default.fileExists(atPath: $0.appending(path: "train.jsonl").path)
    }.max {
      let l = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
      let r = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
      return l < r
    }
  }

  private func latestCheckpoint(in adapter: URL) -> (step: Int, date: Date?)? {
    guard
      let urls = try? FileManager.default.contentsOfDirectory(
        at: adapter, includingPropertiesForKeys: [.contentModificationDateKey])
    else { return nil }
    return urls.compactMap { url -> (Int, Date?)? in
      let name = url.lastPathComponent
      guard name.hasSuffix("_adapters.safetensors"),
        let step = Int(name.prefix(while: \.isNumber))
      else { return nil }
      return (step, try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
    }.max { $0.0 < $1.0 }
  }

  private func lineCount(at url: URL) -> Int {
    guard let data = try? Data(contentsOf: url),
      let text = String(data: data, encoding: .utf8)
    else { return 0 }
    return text.split(whereSeparator: \.isNewline).count
  }

  private func trainingLog(for command: String?, in root: URL) -> URL? {
    if let command, let outputPath = argument("--output-path", in: command) {
      let adapterName = URL(fileURLWithPath: outputPath).lastPathComponent
      let logName: String
      if adapterName.hasPrefix("adapter_dashboard_") {
        logName =
          "train_dashboard_" + String(adapterName.dropFirst("adapter_dashboard_".count)) + ".log"
      } else if adapterName.hasPrefix("adapter") {
        logName = "train" + String(adapterName.dropFirst("adapter".count)) + ".log"
      } else {
        logName = "training.log"
      }
      let candidate = root.appending(path: String(logName))
      if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
    }
    return newestLog(prefix: "train", in: root)
  }

  private func argument(_ name: String, in command: String) -> String? {
    guard let range = command.range(of: name + " ") else { return nil }
    let value = command[range.upperBound...].split(whereSeparator: \.isWhitespace).first
    return value.map(String.init)
  }

  private func newestLog(prefix: String, in root: URL) -> URL? {
    guard
      let urls = try? FileManager.default.contentsOfDirectory(
        at: root,
        includingPropertiesForKeys: [.contentModificationDateKey],
        options: [.skipsHiddenFiles]
      )
    else { return nil }
    return
      urls
      .filter { $0.lastPathComponent.hasPrefix(prefix) && $0.pathExtension == "log" }
      .max {
        let left =
          (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
          ?? .distantPast
        let right =
          (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
          ?? .distantPast
        return left < right
      }
  }

  private func parseTrainingLog(at url: URL, into snapshot: inout TrainingDashboardSnapshot) {
    guard let handle = try? FileHandle(forReadingFrom: url) else { return }
    defer { try? handle.close() }
    do {
      let end = try handle.seekToEnd()
      try handle.seek(toOffset: end > 2_000_000 ? end - 2_000_000 : 0)
      let text = String(decoding: try handle.readToEnd() ?? Data(), as: UTF8.self)
        .replacingOccurrences(of: "\r", with: "\n")
      let progress = try NSRegularExpression(
        pattern:
          #"(\d+)/(\d+)\s+\[([0-9:]+)<([^,]+),\s*([0-9.]+)s/it,\s*loss=([0-9.]+)(?:,\s*lr=([0-9.e+-]+))?"#
      )
      var losses: [TrainingMetricPoint] = []
      var rates: [Double] = []
      var stepTimes: [TrainingMetricPoint] = []
      for line in text.split(whereSeparator: \.isNewline) {
        let lineString = String(line)
        if let match = progress.firstMatch(
          in: lineString,
          range: NSRange(lineString.startIndex..., in: lineString)
        ), match.numberOfRanges == 8,
          let step = integer(in: lineString, range: match.range(at: 1)),
          let total = integer(in: lineString, range: match.range(at: 2)),
          let loss = double(in: lineString, range: match.range(at: 6))
        {
          snapshot.trainingStep = step
          snapshot.totalSteps = total
          snapshot.trainingLoss = loss
          snapshot.elapsedSeconds = seconds(in: lineString, range: match.range(at: 3))
          snapshot.estimatedSecondsRemaining = seconds(in: lineString, range: match.range(at: 4))
          if let rate = double(in: lineString, range: match.range(at: 5)) {
            rates.append(rate)
            stepTimes.append(TrainingMetricPoint(step: step, value: rate))
          }
          if let lr = double(in: lineString, range: match.range(at: 7)) { snapshot.learningRate = lr }
          if losses.last?.step != step { losses.append(TrainingMetricPoint(step: step, value: loss)) }
        }
        if let value = capturedDouble(#"val_loss[=:]\s*([0-9.]+)"#, in: lineString) {
          snapshot.validationLoss = value
          snapshot.validationLosses.append(
            TrainingMetricPoint(
              step: snapshot.trainingStep ?? snapshot.validationLosses.count, value: value)
          )
        }
        if let value = capturedDouble(#"val_token_accuracy[=:]\s*([0-9.]+)"#, in: lineString) {
          snapshot.validationAccuracy = value
        }
      }
      if !rates.isEmpty {
        let window = rates.suffix(30)
        snapshot.secondsPerStep = window.reduce(0, +) / Double(window.count)
      }
      let keep = max(1, stepTimes.count / 300 + 1)
      snapshot.stepTimes = stepTimes.enumerated().filter { $0.offset % keep == 0 }.map(\.element)
      snapshot.firstLoss = losses.first?.value
      snapshot.bestLoss = losses.map(\.value).min()
      // The trainer repeats each reported loss until the next report, so average distinct values.
      var distinct: [Double] = []
      for point in losses.reversed() where distinct.last != point.value {
        distinct.append(point.value)
        if distinct.count == 10 { break }
      }
      if !distinct.isEmpty { snapshot.recentAverageLoss = distinct.reduce(0, +) / Double(distinct.count) }
      var reported: [TrainingMetricPoint] = []
      for point in losses where reported.last?.value != point.value { reported.append(point) }
      snapshot.trainingLosses = reported.count > 300
        ? stride(from: 0, to: reported.count, by: Int((Double(reported.count) / 300).rounded(.up))).map { reported[$0] }
        : reported
      snapshot.validationLosses = Array(snapshot.validationLosses.suffix(100))
    } catch {
      snapshot.errorMessage = "Could not read the training log: \(error.localizedDescription)"
    }
  }

  private func lastEvaluationSummary(at url: URL) -> String? {
    guard let data = try? Data(contentsOf: url),
      let text = String(data: data, encoding: .utf8)
    else { return nil }
    return
      text
      .split(whereSeparator: \.isNewline)
      .last(where: { $0.contains("valid JSON") })
      .map(String.init)
  }

  private func lastEvaluationProgress(at url: URL) -> String? {
    guard let data = try? Data(contentsOf: url),
      let text = String(data: data, encoding: .utf8)
    else { return nil }
    return
      text
      .split(whereSeparator: \.isNewline)
      .last(where: {
        $0.contains("gold=") || $0.contains("FAIL") || $0.contains("INVALID APP PLAN")
      })
      .map(String.init)
  }

  private func newestAdapter(in root: URL) -> URL? {
    guard
      let urls = try? FileManager.default.contentsOfDirectory(
        at: root,
        includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey],
        options: [.skipsHiddenFiles]
      )
    else { return nil }
    return
      urls
      .filter {
        $0.lastPathComponent.hasPrefix("adapter")
          && (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
          && FileManager.default.fileExists(atPath: $0.appending(path: "adapters.safetensors").path)
      }
      .max {
        let left =
          (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
          ?? .distantPast
        let right =
          (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
          ?? .distantPast
        return left < right
      }
  }

  private func checkpointCount(in adapter: URL) -> Int {
    guard
      let urls = try? FileManager.default.contentsOfDirectory(
        at: adapter,
        includingPropertiesForKeys: nil,
        options: [.skipsHiddenFiles]
      )
    else { return 0 }
    return urls.filter {
      $0.pathExtension == "safetensors" && $0.lastPathComponent != "adapters.safetensors"
    }.count
  }

  private func integer(in text: String, range: NSRange) -> Int? {
    guard let range = Range(range, in: text) else { return nil }
    return Int(text[range])
  }

  private func double(in text: String, range: NSRange) -> Double? {
    guard let range = Range(range, in: text) else { return nil }
    return Double(text[range])
  }

  private func seconds(in text: String, range: NSRange) -> Int? {
    guard let range = Range(range, in: text) else { return nil }
    let value = text[range].trimmingCharacters(in: .whitespaces)
    if let seconds = Double(value) { return Int(seconds) }
    let parts = value.split(separator: ":").compactMap { Int($0) }
    guard !parts.isEmpty else { return nil }
    return parts.reversed().enumerated().reduce(0) { total, part in
      total + part.element * Int(pow(60.0, Double(part.offset)))
    }
  }

  private func capturedDouble(_ pattern: String, in text: String) -> Double? {
    guard let expression = try? NSRegularExpression(pattern: pattern),
      let match = expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
      let range = Range(match.range(at: 1), in: text)
    else { return nil }
    return Double(text[range])
  }
}

private enum DashboardError: LocalizedError {
  case operationAlreadyRunning(String)
  case missingResource(String)
  case serverUnavailable(String)
  case processSignalFailed(String)
  case logCreationFailed(String)
  case processListFailed(String)

  var errorDescription: String? {
    switch self {
    case .operationAlreadyRunning(let message),
      .missingResource(let message),
      .serverUnavailable(let message),
      .processSignalFailed(let message),
      .logCreationFailed(let message),
      .processListFailed(let message):
      message
    }
  }
}

@MainActor
struct TrainingDashboardView: View {
  @State private var service = TrainingDashboardService()
  @State private var snapshot = TrainingDashboardSnapshot()
  @State private var trainingFolder: URL?
  @State private var securityScopeActive = false
  @State private var isChoosingFolder = false
  @State private var isStartingTraining = false
  @State private var isStartingValidation = false
  @State private var isStartingServer = false
  @State private var showStopConfirmation = false
  @State private var stopTarget: TrainingStopTarget?
  @State private var statusMessage: String?
  @State private var sampler = SystemMetricsSampler()
  @State private var metrics = SystemMetrics()
  @State private var history: [SystemHistoryPoint] = []
  @State private var historyCounter = 0

  private let bookmarkKey = "trainingDashboard.folderBookmark"

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        VStack(alignment: .leading, spacing: 4) {
          Text("Training Dashboard")
            .font(.title2.weight(.semibold))
          Text("Live MLX training stats, validation, model outputs, and the training drive.")
            .foregroundStyle(.secondary)
        }
        Spacer()
        liveBadge
      }
      .padding()

      ScrollView {
        VStack(alignment: .leading, spacing: 12) {
          GroupBox("Training folder") {
            HStack {
              VStack(alignment: .leading, spacing: 4) {
                Text(trainingFolder?.path ?? "Select the PlushboiiTraining folder")
                  .font(.system(.body, design: .monospaced))
                  .textSelection(.enabled)
                Text(
                  trainingFolder == nil
                    ? "Choose a folder to begin"
                    : snapshot.isDriveMounted
                      ? (canControl ? "Drive connected · controls enabled" : "Drive connected · read-only monitoring. Choose the folder to enable controls")
                      : "Drive unavailable"
                )
                .font(.caption)
                .foregroundStyle(
                  trainingFolder == nil
                    ? Color.secondary
                    : snapshot.isDriveMounted ? Color.green : Color.orange
                )
              }
              Spacer()
              Button("Choose Folder…", systemImage: "externaldrive") {
                isChoosingFolder = true
              }
              .disabled(snapshot.isBusy)
            }
            if let availableBytes = snapshot.availableBytes {
              LabeledContent(
                "Available space",
                value: ByteCountFormatter.string(fromByteCount: availableBytes, countStyle: .file))
            }
          }

          GroupBox("Health alerts") {
            alertsBanner
              .frame(maxWidth: .infinity, alignment: .leading)
          }

          GroupBox("Live run") {
            VStack(alignment: .leading, spacing: 10) {
              HStack {
                statusIndicator
                Spacer()
                if let age = snapshot.logAge {
                  Text("Log updated \(Int(age))s ago")
                    .font(.caption)
                    .foregroundStyle(age < 90 ? Color.secondary : Color.orange)
                }
              }
              if let step = snapshot.trainingStep, let total = snapshot.totalSteps, total > 0 {
                ProgressView(value: Double(step), total: Double(total))
                HStack {
                  Text(
                    "Step \(step.formatted()) of \(total.formatted()) · \((Double(step) / Double(total) * 100).formatted(.number.precision(.fractionLength(1))))%"
                  )
                  Spacer()
                  if let remaining = snapshot.estimatedSecondsRemaining {
                    Text("ETA \(remaining.formattedDuration)")
                      .foregroundStyle(.secondary)
                  }
                }
                .font(.caption)
              }
              Grid(alignment: .leading, horizontalSpacing: 28, verticalSpacing: 10) {
                GridRow {
                  metric(
                    "Epoch",
                    value: snapshot.epoch.map {
                      "\($0.formatted(.number.precision(.fractionLength(2)))) of \(snapshot.totalEpochs ?? 0)"
                    } ?? "—")
                  metric(
                    "Speed",
                    value: snapshot.secondsPerStep.map {
                      "\($0.formatted(.number.precision(.fractionLength(1)))) s/step · \(Int((snapshot.stepsPerHour ?? 0).rounded())) steps/h"
                    } ?? "—")
                  metric(
                    "Elapsed",
                    value: snapshot.elapsedSeconds.map(\.formattedDuration) ?? "—")
                }
                GridRow {
                  metric(
                    "Estimated finish",
                    value: snapshot.estimatedFinish.map {
                      $0.formatted(date: .abbreviated, time: .shortened)
                    } ?? "—")
                  metric(
                    "Loss now / avg(10) / best",
                    value: lossSummary)
                  metric(
                    "Learning rate",
                    value: snapshot.learningRate.map { String(format: "%.2e", $0) } ?? "—")
                }
                GridRow {
                  metric(
                    "Trainer process",
                    value: snapshot.trainingPID.map { pid in
                      var parts = ["PID \(pid)"]
                      if let cpu = snapshot.cpuPercent { parts.append("\(Int(cpu))% CPU") }
                      if let memory = snapshot.residentMemoryBytes {
                        parts.append(ByteCountFormatter.string(fromByteCount: memory, countStyle: .memory))
                      }
                      return parts.joined(separator: " · ")
                    } ?? "Not running")
                  metric(
                    "Last checkpoint",
                    value: snapshot.lastCheckpointStep.map { step in
                      let when = snapshot.lastCheckpointAt.map {
                        " · " + $0.formatted(date: .omitted, time: .shortened)
                      } ?? ""
                      return "Step \(step.formatted())\(when)"
                    } ?? "None yet")
                  metric("Validation", value: snapshot.evaluationPID.map { "PID \($0)" } ?? "Idle")
                }
                GridRow {
                  metric("MLX server", value: snapshot.serverPID.map { "PID \($0)" } ?? "Stopped")
                  metric("Log file", value: snapshot.logName ?? "—")
                  metric("Process detection", value: snapshot.processDetection)
                }
              }
            }
          }

          GroupBox("Queued pipeline & watchdog reports") {
            VStack(alignment: .leading, spacing: 8) {
              Grid(alignment: .leading, horizontalSpacing: 28, verticalSpacing: 8) {
                GridRow {
                  metric("Anatomy4 pipeline", value: snapshot.queuedPipelineStatus ?? "Unavailable")
                  metric(
                    "Outdated packages",
                    value: snapshot.outdatedPackageCount.map { String($0) } ?? "Not reported")
                }
                GridRow {
                  metric(
                    "Dataset candidates",
                    value: snapshot.datasetCandidateCount.map { count in
                      "\(count) · \(snapshot.licensedDatasetCount ?? 0) with license metadata"
                    } ?? "Not reported")
                  metric("Discovery checked", value: snapshot.discoveryCheckedAt ?? "Not reported")
                }
              }
              if let watchdogReportsPath = snapshot.watchdogReportsPath {
                Button("Open Watchdog Reports", systemImage: "doc.text.magnifyingglass") {
                  NSWorkspace.shared.open(URL(fileURLWithPath: watchdogReportsPath))
                }
              }
              if let message = snapshot.automationReportMessage {
                Text(message)
                  .font(.caption)
                  .foregroundStyle(.secondary)
                  .textSelection(.enabled)
              }
              Text("Status and discovery reports are read-only here. Updates and candidate datasets are never installed or downloaded automatically.")
                .font(.caption)
                .foregroundStyle(.secondary)
            }
          }

          GroupBox("System & app health") {
            VStack(alignment: .leading, spacing: 12) {
              HStack {
                Label(
                  "Strain \(Int(metrics.strainScore))%",
                  systemImage: metrics.strainScore > 80 ? "flame" : "gauge.with.dots.needle.33percent")
                  .foregroundStyle(
                    metrics.strainScore > 80 ? Color.red : metrics.strainScore > 60 ? Color.orange : Color.green)
                Spacer()
                Text("Peak of CPU, memory, swap, pressure and thermal state")
                  .font(.caption).foregroundStyle(.secondary)
              }
              ProgressView(value: min(100, metrics.strainScore), total: 100)
              Grid(alignment: .leading, horizontalSpacing: 28, verticalSpacing: 10) {
                GridRow {
                  metric("Plushboii memory", value: "\(SystemMetrics.bytes(metrics.appFootprintBytes)) footprint · \(SystemMetrics.bytes(metrics.appResidentBytes)) resident")
                  metric("Plushboii CPU", value: "\(Int(metrics.appCPUPercent))% · \(metrics.appThreads) threads")
                  metric("App GPU memory", value: "\(SystemMetrics.bytes(metrics.gpuAllocatedBytes)) of \(SystemMetrics.bytes(metrics.gpuWorkingSetBytes)) · \(metrics.gpuName)")
                }
                GridRow {
                  metric("System memory", value: "\(SystemMetrics.bytes(metrics.usedMemoryBytes)) of \(SystemMetrics.bytes(metrics.totalMemoryBytes)) (\(Int(metrics.memoryUsedPercent))%)")
                  metric("Wired · compressed · cached", value: "\(SystemMetrics.bytes(metrics.wiredBytes)) · \(SystemMetrics.bytes(metrics.compressedBytes)) · \(SystemMetrics.bytes(metrics.cachedBytes))")
                  metric("Swap · pressure", value: "\(SystemMetrics.bytes(metrics.swapUsedBytes)) of \(SystemMetrics.bytes(metrics.swapTotalBytes)) · \(metrics.pressureLevel)")
                }
                GridRow {
                  metric("System CPU", value: "\(Int(metrics.systemCPUPercent))% (user \(Int(metrics.userCPUPercent))%) · \(metrics.coreCount) cores")
                  metric("Load average", value: String(format: "%.2f · %.2f · %.2f", metrics.loadAverage.0, metrics.loadAverage.1, metrics.loadAverage.2))
                  metric("Thermal · power", value: "\(metrics.thermalState)\(metrics.lowPowerMode ? " · Low Power" : "") · \(metrics.batteryPercent.map { "\($0)% \(metrics.onACPower ? "on AC" : "battery")" } ?? "AC desktop")")
                }
                GridRow {
                  metric("Startup disk free", value: diskText(metrics.systemVolumeFreeBytes, metrics.systemVolumeTotalBytes))
                  metric("Training drive free", value: diskText(metrics.trainingVolumeFreeBytes, metrics.trainingVolumeTotalBytes))
                  metric("Uptime", value: "App \(Int(metrics.appUptime).formattedDuration) · Mac \(Int(metrics.systemUptime).formattedDuration)")
                }
              }
              HStack(spacing: 16) {
                gauge("System CPU", value: metrics.systemCPUPercent, label: "\(Int(metrics.systemCPUPercent))%")
                gauge("Memory", value: metrics.memoryUsedPercent, label: "\(Int(metrics.memoryUsedPercent))%")
                gauge(
                  "GPU memory (app)",
                  value: metrics.gpuWorkingSetBytes == 0 ? 0 : Double(metrics.gpuAllocatedBytes) / Double(metrics.gpuWorkingSetBytes) * 100,
                  label: SystemMetrics.bytes(metrics.gpuAllocatedBytes))
                gauge(
                  "Swap",
                  value: metrics.swapTotalBytes == 0 ? 0 : Double(metrics.swapUsedBytes) / Double(metrics.swapTotalBytes) * 100,
                  label: SystemMetrics.bytes(metrics.swapUsedBytes))
                gauge("Startup disk", value: diskUsedPercent(metrics.systemVolumeFreeBytes, metrics.systemVolumeTotalBytes), label: "used")
                gauge("Training drive", value: diskUsedPercent(metrics.trainingVolumeFreeBytes, metrics.trainingVolumeTotalBytes), label: "used")
              }
              memoryBreakdownChart
              if history.count > 1 {
                chartTitle("CPU over time")
                Chart {
                  ForEach(history) { point in
                    LineMark(x: .value("Time", point.time), y: .value("%", point.systemCPU), series: .value("Series", "System"))
                      .foregroundStyle(by: .value("Series", "System"))
                    LineMark(x: .value("Time", point.time), y: .value("%", point.appCPU), series: .value("Series", "Plushboii"))
                      .foregroundStyle(by: .value("Series", "Plushboii"))
                  }
                }
                .chartYAxisLabel("% of one core · system as % of all")
                .frame(height: 130)
                .accessibilityLabel("System and app CPU over the last five minutes")

                chartTitle("Memory over time (GB)")
                Chart {
                  ForEach(history) { point in
                    AreaMark(x: .value("Time", point.time), y: .value("GB", point.trainerMemoryGB), series: .value("Series", "Trainer"))
                      .foregroundStyle(by: .value("Series", "Trainer")).opacity(0.35)
                    LineMark(x: .value("Time", point.time), y: .value("GB", point.appMemoryGB), series: .value("Series", "Plushboii"))
                      .foregroundStyle(by: .value("Series", "Plushboii"))
                    LineMark(x: .value("Time", point.time), y: .value("GB", point.gpuAllocatedGB), series: .value("Series", "App GPU"))
                      .foregroundStyle(by: .value("Series", "App GPU"))
                    LineMark(x: .value("Time", point.time), y: .value("GB", point.swapGB), series: .value("Series", "Swap"))
                      .foregroundStyle(by: .value("Series", "Swap"))
                  }
                }
                .chartYAxisLabel("GB")
                .frame(height: 130)
                .accessibilityLabel("Trainer, app, GPU and swap memory over the last five minutes")

                chartTitle("Strain over time")
                Chart(history) { point in
                  AreaMark(x: .value("Time", point.time), y: .value("Strain", point.strain))
                    .foregroundStyle(.orange.opacity(0.35))
                  LineMark(x: .value("Time", point.time), y: .value("Strain", point.strain))
                    .foregroundStyle(.orange)
                  RuleMark(y: .value("High", 80)).foregroundStyle(.red.opacity(0.5))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                }
                .chartYScale(domain: 0...100)
                .frame(height: 100)
                .accessibilityLabel("Strain score over the last five minutes")
              }
            }
          }

          GroupBox("GPU, temperature & power (macmon)") {
            if let hw = metrics.hardware {
              VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 16) {
                  gauge("GPU load", value: hw.gpuUsagePercent ?? 0, label: hw.gpuFrequencyMHz.map { "\(Int($0)) MHz" } ?? "—")
                  tempGauge("CPU temp", hw.cpuTemperature)
                  tempGauge("GPU temp", hw.gpuTemperature)
                  gauge("P-cores", value: hw.performanceUsagePercent ?? 0, label: hw.performanceFrequencyMHz.map { "\(Int($0)) MHz" } ?? "—")
                  gauge("E-cores", value: hw.efficiencyUsagePercent ?? 0, label: hw.efficiencyFrequencyMHz.map { "\(Int($0)) MHz" } ?? "—")
                  ForEach(hw.fans) { fan in
                    gauge(fan.name.capitalized, value: fan.maxRPM > 0 ? fan.rpm / fan.maxRPM * 100 : 0, label: "\(Int(fan.rpm)) rpm")
                  }
                }
                Chart {
                  ForEach([("CPU", hw.cpuPowerWatts), ("GPU", hw.gpuPowerWatts), ("Neural Engine", hw.anePowerWatts)], id: \.0) { item in
                    BarMark(x: .value("Watts", item.1 ?? 0), y: .value("Component", item.0))
                      .annotation(position: .trailing) {
                        Text(String(format: "%.1f W", item.1 ?? 0)).font(.caption2)
                      }
                  }
                }
                .frame(height: 90)
                .accessibilityLabel("Power draw by component in watts")
                Text("Total system power \(String(format: "%.1f", hw.systemWatts ?? 0)) W")
                  .font(.caption).foregroundStyle(.secondary)
                if history.contains(where: { $0.gpuTemp != nil }) {
                  chartTitle("GPU load, temperatures and power over time")
                  Chart {
                    ForEach(history) { point in
                      if let v = point.gpuUsage {
                        LineMark(x: .value("Time", point.time), y: .value("Value", v), series: .value("Series", "GPU load %"))
                          .foregroundStyle(by: .value("Series", "GPU load %"))
                      }
                      if let v = point.gpuTemp {
                        LineMark(x: .value("Time", point.time), y: .value("Value", v), series: .value("Series", "GPU °C"))
                          .foregroundStyle(by: .value("Series", "GPU °C"))
                      }
                      if let v = point.cpuTemp {
                        LineMark(x: .value("Time", point.time), y: .value("Value", v), series: .value("Series", "CPU °C"))
                          .foregroundStyle(by: .value("Series", "CPU °C"))
                      }
                      if let v = point.systemWatts {
                        LineMark(x: .value("Time", point.time), y: .value("Value", v), series: .value("Series", "System W"))
                          .foregroundStyle(by: .value("Series", "System W"))
                      }
                    }
                  }
                  .frame(height: 140)
                  .accessibilityLabel("GPU load, temperatures and power over the last five minutes")
                }
              }
            } else {
              VStack(alignment: .leading, spacing: 6) {
                Label("macmon is not reachable on 127.0.0.1:9090", systemImage: "thermometer.slash")
                  .foregroundStyle(.orange)
                Text("Install and start it with: brew install macmon && macmon serve --host 127.0.0.1 --port 9090 --install")
                  .font(.system(.caption, design: .monospaced))
                  .textSelection(.enabled)
              }
            }
          }

          GroupBox("AI services") {
            Grid(alignment: .leading, horizontalSpacing: 28, verticalSpacing: 10) {
              GridRow {
                metric("MLX server (8080)", value: serviceText(metrics.mlx))
                metric("Trainer", value: snapshot.trainingPID.map { _ in
                  "\(Int(snapshot.cpuPercent ?? 0))% CPU · \(SystemMetrics.bytes(UInt64(snapshot.residentMemoryBytes ?? 0))) RAM · up \(snapshot.processUptime ?? "—")"
                } ?? "Not running")
                metric("Trainer share of RAM", value: metrics.totalMemoryBytes > 0
                  ? "\((Double(snapshot.residentMemoryBytes ?? 0) / Double(metrics.totalMemoryBytes) * 100).formatted(.number.precision(.fractionLength(1))))%" : "—")
              }
            }
          }

          GroupBox("Training metrics") {
            Grid(alignment: .leading, horizontalSpacing: 28, verticalSpacing: 10) {
              GridRow {
                metric(
                  "Train loss",
                  value: snapshot.trainingLoss?.formatted(.number.precision(.fractionLength(4)))
                    ?? "—")
                metric(
                  "Validation loss",
                  value: snapshot.validationLoss?.formatted(.number.precision(.fractionLength(4)))
                    ?? "Not logged by trainer")
              }
              GridRow {
                metric(
                  "Token accuracy",
                  value: snapshot.validationAccuracy.map {
                    "\(($0 * 100).formatted(.number.precision(.fractionLength(1))))%"
                  } ?? "—")
                metric(
                  "Dataset",
                  value:
                    "\(snapshot.datasetName ?? "—"): \(snapshot.trainingSamples.formatted()) train · \(snapshot.validationSamples.formatted()) validation"
                )
              }
              GridRow {
                metric("Base model", value: "Gemma 4 E4B IT 4-bit")
                metric("Checkpoints", value: snapshot.checkpointCount.formatted())
              }
              GridRow {
                metric(
                  "Latest adapter",
                  value: snapshot.adapterPath.map { URL(fileURLWithPath: $0).lastPathComponent }
                    ?? "Not found")
                metric("Evaluation", value: snapshot.evaluationProgress ?? "No active validation")
              }
            }
            if !snapshot.trainingLosses.isEmpty || !snapshot.validationLosses.isEmpty {
              Chart {
                ForEach(snapshot.trainingLosses) { point in
                  LineMark(
                    x: .value("Step", point.step),
                    y: .value("Loss", point.value),
                    series: .value("Series", "Train")
                  )
                  .foregroundStyle(.blue)
                }
                ForEach(snapshot.validationLosses) { point in
                  LineMark(
                    x: .value("Step", point.step),
                    y: .value("Loss", point.value),
                    series: .value("Series", "Validation")
                  )
                  .foregroundStyle(.orange)
                  .lineStyle(StrokeStyle(lineWidth: 2, dash: [4, 3]))
                }
              }
              .chartXAxisLabel("Step")
              .chartYAxisLabel("Loss")
              .frame(height: 180)
              .accessibilityLabel("Training and validation loss chart")
            }
            if snapshot.stepTimes.count > 1 {
              chartTitle("Seconds per step")
              Chart(snapshot.stepTimes) { point in
                LineMark(x: .value("Step", point.step), y: .value("s/step", point.value))
                  .foregroundStyle(.purple)
                RuleMark(y: .value("Average", snapshot.secondsPerStep ?? 0))
                  .foregroundStyle(.secondary)
                  .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
              }
              .chartXAxisLabel("Step")
              .frame(height: 110)
              .accessibilityLabel("Seconds per training step")
            }
            if let evaluationSummary = snapshot.evaluationSummary {
              Text(evaluationSummary)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
            }
          }

          GroupBox("Controls") {
            HStack {
              Button {
                startTraining()
              } label: {
                Label(isStartingTraining ? "Starting…" : "Start Training", systemImage: "play.fill")
              }
              .disabled(
                !canControl || snapshot.isBusy || snapshot.serverPID != nil
                  || isStartingTraining || isStartingValidation || isStartingServer)

              Button {
                requestStop(.training)
              } label: {
                Label("Stop Training", systemImage: "stop.fill")
              }
              .disabled(snapshot.trainingPID == nil)

              Button {
                startValidation()
              } label: {
                Label(
                  isStartingValidation ? "Starting…" : "Run Validation",
                  systemImage: "checkmark.seal")
              }
              .disabled(
                !canControl || snapshot.isBusy || snapshot.adapterPath == nil
                  || isStartingTraining || isStartingValidation || isStartingServer)

              Button {
                requestStop(.evaluation)
              } label: {
                Label("Stop Validation", systemImage: "stop")
              }
              .disabled(snapshot.evaluationPID == nil)
            }
            HStack {
              Button {
                startServer()
              } label: {
                Label(
                  isStartingServer ? "Starting…" : "Start MLX Server", systemImage: "server.rack")
              }
              .disabled(
                !canControl || snapshot.serverPID != nil || snapshot.isBusy
                  || isStartingTraining || isStartingValidation || isStartingServer)

              Button {
                requestStop(.server)
              } label: {
                Label("Stop MLX Server", systemImage: "stop.circle")
              }
              .disabled(snapshot.serverPID == nil)

              Button("Open Training Folder", systemImage: "folder") {
                openTrainingFolder()
              }
              .disabled(trainingFolder == nil || !snapshot.isDriveMounted)
              Spacer()
            }
            if let message = statusMessage ?? snapshot.errorMessage {
              Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            }
            Text(
              "Training and validation are mutually exclusive. Stop controls send an interrupt and require confirmation. Logs and adapters stay in the selected folder."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
          }
        }
        .padding(.horizontal)
      }
    }
    .frame(minWidth: 760, minHeight: 650)
    .background(DashboardTabAttacher())
    .fileImporter(
      isPresented: $isChoosingFolder,
      allowedContentTypes: [.folder],
      allowsMultipleSelection: false
    ) { result in
      switch result {
      case .success(let urls):
        if let url = urls.first { selectTrainingFolder(url) }
      case .failure(let error):
        statusMessage = error.localizedDescription
      }
    }
    .confirmationDialog(
      stopDialogTitle,
      isPresented: $showStopConfirmation,
      titleVisibility: .visible
    ) {
      Button(stopButtonTitle, role: .destructive) {
        stopSelectedProcess()
      }
      Button("Cancel", role: .cancel) { stopTarget = nil }
    } message: {
      Text(stopDialogMessage)
    }
    .task {
      restoreFolderBookmark()
      await refreshSnapshot()
      while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(2))
        if Task.isCancelled { break }
        await refreshSnapshot()
      }
    }
    .task {
      while !Task.isCancelled {
        let next = await sampler.sample(trainingRoot: trainingFolder)
        metrics = next
        historyCounter += 1
        history.append(
          SystemHistoryPoint(
            id: historyCounter, time: next.sampledAt, appCPU: next.appCPUPercent,
            systemCPU: next.systemCPUPercent,
            appMemoryGB: Double(next.appFootprintBytes) / 1_073_741_824,
            systemMemoryUsedPercent: next.memoryUsedPercent,
            gpuAllocatedGB: Double(next.gpuAllocatedBytes) / 1_073_741_824,
            trainerMemoryGB: Double(snapshot.residentMemoryBytes ?? 0) / 1_073_741_824,
            swapGB: Double(next.swapUsedBytes) / 1_073_741_824,
            strain: next.strainScore,
            gpuUsage: next.hardware?.gpuUsagePercent,
            cpuTemp: next.hardware?.cpuTemperature,
            gpuTemp: next.hardware?.gpuTemperature,
            systemWatts: next.hardware?.systemWatts))
        if history.count > 150 { history.removeFirst(history.count - 150) }
        try? await Task.sleep(for: .seconds(2))
      }
    }
    .onDisappear {
      if securityScopeActive, let trainingFolder {
        trainingFolder.stopAccessingSecurityScopedResource()
      }
    }
  }

  private static let defaultFolder = URL(
    fileURLWithPath: "/Volumes/AMITA/PlushboiiTraining", isDirectory: true)

  private func gauge(_ title: String, value: Double, label: String) -> some View {
    VStack(spacing: 4) {
      Gauge(value: min(100, max(0, value)), in: 0...100) {
        Text(title)
      } currentValueLabel: {
        Text("\(Int(value))%").font(.caption2)
      }
      .gaugeStyle(.accessoryCircularCapacity)
      .tint(Gradient(colors: [.green, .yellow, .orange, .red]))
      Text(title).font(.caption).multilineTextAlignment(.center)
      Text(label).font(.caption2).foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity)
    .accessibilityElement(children: .combine)
  }

  private func tempGauge(_ title: String, _ celsius: Double?) -> some View {
    VStack(spacing: 4) {
      Gauge(value: min(110, max(0, celsius ?? 0)), in: 20...110) {
        Text(title)
      } currentValueLabel: {
        Text(celsius.map { "\(Int($0))°" } ?? "—").font(.caption2)
      }
      .gaugeStyle(.accessoryCircularCapacity)
      .tint(Gradient(colors: [.green, .yellow, .orange, .red]))
      Text(title).font(.caption)
      Text(celsius.map { $0 >= 95 ? "Very hot" : $0 >= 85 ? "Hot" : "OK" } ?? "No data")
        .font(.caption2).foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity)
    .accessibilityElement(children: .combine)
  }

  private func chartTitle(_ text: String) -> some View {
    Text(text).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
  }

  private func diskUsedPercent(_ free: Int64?, _ total: Int64?) -> Double {
    guard let free, let total, total > 0 else { return 0 }
    return Double(total - free) / Double(total) * 100
  }

  private var memoryBreakdownChart: some View {
    let gb = { (bytes: UInt64) in Double(bytes) / 1_073_741_824 }
    let other = metrics.usedMemoryBytes > metrics.wiredBytes + metrics.compressedBytes
      ? metrics.usedMemoryBytes - metrics.wiredBytes - metrics.compressedBytes : 0
    let parts: [(String, Double)] = [
      ("Wired", gb(metrics.wiredBytes)), ("Compressed", gb(metrics.compressedBytes)),
      ("App & other", gb(other)), ("Cached files", gb(metrics.cachedBytes)),
      ("Free", gb(metrics.freeBytes)),
    ]
    return VStack(alignment: .leading, spacing: 4) {
      chartTitle("Memory breakdown (GB of \(SystemMetrics.bytes(metrics.totalMemoryBytes)))")
      Chart(parts, id: \.0) { part in
        BarMark(x: .value("GB", part.1))
          .foregroundStyle(by: .value("Kind", part.0))
      }
      .chartXScale(domain: 0...max(1, gb(metrics.totalMemoryBytes)))
      .frame(height: 50)
      .accessibilityLabel("Memory breakdown by kind")
    }
  }

  private func diskText(_ free: Int64?, _ total: Int64?) -> String {
    guard let free, let total, total > 0 else { return "—" }
    return "\(ByteCountFormatter.string(fromByteCount: free, countStyle: .file)) of \(ByteCountFormatter.string(fromByteCount: total, countStyle: .file))"
  }

  private func serviceText(_ probe: ServiceProbe) -> String {
    probe.isUp
      ? "Up · \(probe.latencyMilliseconds.map { String(format: "%.0f ms", $0) } ?? probe.detail)"
      : "Down · \(probe.detail)"
  }

  private var alerts: [HealthAlert] {
    HealthThresholds.alerts(
      metrics: metrics,
      snapshot: TrainingAlertInput(trainerRunning: snapshot.isTraining, logAge: snapshot.logAge),
      history: history)
  }

  private var alertsBanner: some View {
    let items = alerts
    return Group {
      if items.isEmpty {
        Label("All monitored readings are within normal ranges", systemImage: "checkmark.shield")
          .font(.callout).foregroundStyle(.green)
      } else {
        VStack(alignment: .leading, spacing: 8) {
          ForEach(items) { alert in
            HStack(alignment: .top, spacing: 8) {
              Image(systemName: alert.severity == .danger ? "exclamationmark.octagon.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(alert.severity == .danger ? Color.red : Color.orange)
              VStack(alignment: .leading, spacing: 2) {
                Text(alert.title).font(.callout.weight(.semibold))
                Text(alert.advice).font(.caption).foregroundStyle(.secondary)
              }
              Spacer()
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(alert.severity == .danger ? "Danger" : "Caution"): \(alert.title). \(alert.advice)")
          }
          Text("Temperature, swap and disk limits are conservative heuristics, not Apple specifications. Memory pressure and thermal state are macOS levels.")
            .font(.caption2).foregroundStyle(.tertiary)
        }
      }
    }
  }

  private var canControl: Bool { trainingFolder != nil && securityScopeActive }

  private var lossSummary: String {
    func f(_ v: Double?) -> String { v.map { $0.formatted(.number.precision(.fractionLength(4))) } ?? "—" }
    return "\(f(snapshot.trainingLoss)) / \(f(snapshot.recentAverageLoss)) / \(f(snapshot.bestLoss))"
  }

  private var liveBadge: some View {
    HStack(spacing: 6) {
      Circle()
        .fill(snapshot.isLive ? Color.green : Color.secondary)
        .frame(width: 8, height: 8)
      Text(snapshot.isLive ? "LIVE · 2s refresh" : "Not live")
        .font(.caption.weight(.semibold))
        .foregroundStyle(snapshot.isLive ? Color.green : Color.secondary)
    }
    .accessibilityElement(children: .combine)
  }

  @ViewBuilder
  private var statusIndicator: some View {
    if snapshot.isTraining {
      Label("Training", systemImage: "arrow.triangle.2.circlepath")
        .foregroundStyle(.blue)
    } else if snapshot.isEvaluating {
      Label("Validating", systemImage: "checkmark.seal")
        .foregroundStyle(.orange)
    } else if snapshot.trainingStep == snapshot.totalSteps, snapshot.totalSteps != nil {
      Label("Training complete", systemImage: "checkmark.circle")
        .foregroundStyle(.green)
    } else if !snapshot.isDriveMounted, trainingFolder != nil {
      Label("Drive disconnected", systemImage: "externaldrive.badge.xmark")
        .foregroundStyle(.orange)
    } else {
      Label("Idle", systemImage: "pause.circle")
        .foregroundStyle(.secondary)
    }
  }

  private var stopDialogTitle: String {
    switch stopTarget {
    case .training: "Stop the training run?"
    case .evaluation: "Stop validation?"
    case .server: "Stop the MLX server?"
    case nil: "Stop this process?"
    }
  }

  private var stopButtonTitle: String {
    switch stopTarget {
    case .training: "Stop Training"
    case .evaluation: "Stop Validation"
    case .server: "Stop Server"
    case nil: "Stop"
    }
  }

  private var stopDialogMessage: String {
    switch stopTarget {
    case .training:
      "The trainer will receive an interrupt. Saved checkpoints and logs will remain in the training folder."
    case .evaluation:
      "The validation process will receive an interrupt. Its log will remain in the training folder."
    case .server: "The MLX server will receive an interrupt. Any active app request may fail."
    case nil: ""
    }
  }

  private func metric(_ title: String, value: String) -> some View {
    VStack(alignment: .leading, spacing: 3) {
      Text(title)
        .font(.caption)
        .foregroundStyle(.secondary)
      Text(value)
        .font(.callout.weight(.medium))
        .textSelection(.enabled)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func selectTrainingFolder(_ url: URL) {
    if securityScopeActive, let trainingFolder {
      trainingFolder.stopAccessingSecurityScopedResource()
    }
    let didStartScope = url.startAccessingSecurityScopedResource()
    guard FileManager.default.fileExists(atPath: url.appending(path: "run_train.py").path) else {
      if didStartScope { url.stopAccessingSecurityScopedResource() }
      statusMessage = "Choose the PlushboiiTraining folder containing run_train.py."
      return
    }
    do {
      let bookmark = try url.bookmarkData(
        options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
      UserDefaults.standard.set(bookmark, forKey: bookmarkKey)
      trainingFolder = url
      securityScopeActive = didStartScope
      statusMessage = nil
      Task { await refreshSnapshot() }
    } catch {
      if didStartScope { url.stopAccessingSecurityScopedResource() }
      statusMessage = "Could not save folder access: \(error.localizedDescription)"
    }
  }

  private func restoreFolderBookmark() {
    guard let bookmark = UserDefaults.standard.data(forKey: bookmarkKey) else {
      trainingFolder = Self.defaultFolder
      return
    }
    do {
      var stale = false
      let url = try URL(
        resolvingBookmarkData: bookmark,
        options: [.withSecurityScope],
        relativeTo: nil,
        bookmarkDataIsStale: &stale
      )
      securityScopeActive = url.startAccessingSecurityScopedResource()
      trainingFolder = url
      if stale {
        let refreshed = try url.bookmarkData(
          options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
        UserDefaults.standard.set(refreshed, forKey: bookmarkKey)
      }
    } catch {
      trainingFolder = Self.defaultFolder
      statusMessage =
        "The saved training-folder access expired. Choose the folder again. \(error.localizedDescription)"
    }
  }

  private func refreshSnapshot() async {
    guard let trainingFolder else { return }
    snapshot = await service.snapshot(at: trainingFolder)
  }

  private func startTraining() {
    guard let trainingFolder else { return }
    statusMessage = nil
    isStartingTraining = true
    Task {
      defer { isStartingTraining = false }
      do {
        try await service.startTraining(at: trainingFolder)
        statusMessage =
          "Training started. Logs and adapter output are being written to the selected folder."
        await refreshSnapshot()
      } catch {
        statusMessage = error.localizedDescription
      }
    }
  }

  private func startValidation() {
    guard let trainingFolder else { return }
    statusMessage = nil
    isStartingValidation = true
    Task {
      defer { isStartingValidation = false }
      do {
        try await service.startValidation(at: trainingFolder)
        statusMessage = "Validation started. The selected adapter is being scored against anatomy3."
        await refreshSnapshot()
      } catch {
        statusMessage = error.localizedDescription
      }
    }
  }

  private func startServer() {
    guard let trainingFolder else { return }
    statusMessage = nil
    isStartingServer = true
    Task {
      defer { isStartingServer = false }
      do {
        try await service.startServer(at: trainingFolder)
        statusMessage = "MLX server started on 127.0.0.1:8080."
        await refreshSnapshot()
      } catch {
        statusMessage = error.localizedDescription
      }
    }
  }

  private func requestStop(_ target: TrainingStopTarget) {
    stopTarget = target
    showStopConfirmation = true
  }

  private func stopSelectedProcess() {
    guard let target = stopTarget, let trainingFolder else { return }
    stopTarget = nil
    statusMessage = nil
    Task {
      do {
        try await service.stop(target, in: trainingFolder)
        statusMessage = "Interrupt requested."
        await refreshSnapshot()
      } catch {
        statusMessage = error.localizedDescription
      }
    }
  }

  private func openTrainingFolder() {
    guard let trainingFolder else { return }
    if !NSWorkspace.shared.open(trainingFolder) {
      statusMessage = "Could not open the training folder in Finder."
    }
  }
}

extension Int {
  fileprivate var formattedDuration: String {
    let hours = self / 3600
    let minutes = (self % 3600) / 60
    let seconds = self % 60
    if hours > 0 { return "\(hours)h \(minutes)m" }
    if minutes > 0 { return "\(minutes)m \(seconds)s" }
    return "\(seconds)s"
  }
}


struct DashboardTabAttacher: NSViewRepresentable {
  func makeNSView(context: Context) -> NSView { NSView() }

  func updateNSView(_ view: NSView, context: Context) {
    Task { @MainActor in
      guard let window = view.window, window.tabbedWindows == nil else { return }
      window.tabbingMode = .preferred
      guard
        let host = NSApp.windows.first(where: {
          $0 !== window && $0.isVisible && $0.canBecomeMain && $0.title != "Training Dashboard"
        })
      else { return }
      host.tabbingMode = .preferred
      host.addTabbedWindow(window, ordered: .above)
      window.makeKeyAndOrderFront(nil)
    }
  }
}


struct FanReading: Sendable, Identifiable {
  let name: String
  let rpm: Double
  let maxRPM: Double
  var id: String { name }
}

struct HardwareReading: Sendable {
  var cpuTemperature: Double?
  var gpuTemperature: Double?
  var gpuUsagePercent: Double?
  var gpuFrequencyMHz: Double?
  var cpuPowerWatts: Double?
  var gpuPowerWatts: Double?
  var anePowerWatts: Double?
  var systemWatts: Double?
  var efficiencyFrequencyMHz: Double?
  var performanceFrequencyMHz: Double?
  var efficiencyUsagePercent: Double?
  var performanceUsagePercent: Double?
  var fans: [FanReading] = []
}

struct SystemHistoryPoint: Identifiable, Sendable {
  let id: Int
  let time: Date
  let appCPU: Double
  let systemCPU: Double
  let appMemoryGB: Double
  let systemMemoryUsedPercent: Double
  let gpuAllocatedGB: Double
  let trainerMemoryGB: Double
  let swapGB: Double
  let strain: Double
  let gpuUsage: Double?
  let cpuTemp: Double?
  let gpuTemp: Double?
  let systemWatts: Double?
}

struct ServiceProbe: Sendable {
  var name: String
  var isUp = false
  var latencyMilliseconds: Double?
  var detail = ""
}

struct SystemMetrics: Sendable {
  var appResidentBytes: UInt64 = 0
  var appFootprintBytes: UInt64 = 0
  var appCPUPercent = 0.0
  var appThreads = 0
  var appUptime: TimeInterval = 0
  var gpuAllocatedBytes: UInt64 = 0
  var gpuWorkingSetBytes: UInt64 = 0
  var gpuName = "—"
  var unifiedMemory = false

  var totalMemoryBytes: UInt64 = 0
  var usedMemoryBytes: UInt64 = 0
  var wiredBytes: UInt64 = 0
  var compressedBytes: UInt64 = 0
  var cachedBytes: UInt64 = 0
  var freeBytes: UInt64 = 0
  var swapUsedBytes: UInt64 = 0
  var swapTotalBytes: UInt64 = 0
  var pressureLevel = "Normal"

  var systemCPUPercent = 0.0
  var userCPUPercent = 0.0
  var coreCount = 0
  var loadAverage: (Double, Double, Double) = (0, 0, 0)
  var thermalState = "Nominal"
  var lowPowerMode = false
  var batteryPercent: Int?
  var onACPower = true
  var systemUptime: TimeInterval = 0

  var systemVolumeFreeBytes: Int64?
  var systemVolumeTotalBytes: Int64?
  var trainingVolumeFreeBytes: Int64?
  var trainingVolumeTotalBytes: Int64?

  var mlx = ServiceProbe(name: "MLX server")
  var hardware: HardwareReading?

  var sampledAt = Date()

  var memoryUsedPercent: Double {
    totalMemoryBytes == 0 ? 0 : Double(usedMemoryBytes) / Double(totalMemoryBytes) * 100
  }
  var strainScore: Double {
    let thermal: Double =
      switch thermalState {
      case "Fair": 25
      case "Serious": 60
      case "Critical": 100
      default: 0
      }
    let pressure: Double =
      switch pressureLevel {
      case "Warning": 50
      case "Critical": 100
      default: 0
      }
    let swap = swapTotalBytes == 0 ? 0 : min(100, Double(swapUsedBytes) / Double(swapTotalBytes) * 100)
    let temp = max(hardware?.cpuTemperature ?? 0, hardware?.gpuTemperature ?? 0)
    let tempScore = temp >= 100 ? 100 : temp >= 90 ? 80 : temp >= 80 ? 60 : 0
    return max(systemCPUPercent, memoryUsedPercent, thermal, pressure, swap, Double(tempScore))
  }
}

actor SystemMetricsSampler {
  private var previousTicks: (user: UInt32, system: UInt32, idle: UInt32, nice: UInt32)?
  private let launchDate = Date()

  func sample(trainingRoot: URL?) async -> SystemMetrics {
    var metrics = SystemMetrics()
    sampleApp(into: &metrics)
    sampleMemory(into: &metrics)
    sampleCPU(into: &metrics)
    samplePower(into: &metrics)
    sampleDisks(into: &metrics, trainingRoot: trainingRoot)
    async let hardware = readMacmon()
    async let mlx = probe(name: "MLX server", url: "http://127.0.0.1:8080/health")
    let (m, h) = await (mlx, hardware)
    metrics.hardware = h
    metrics.mlx = m
    metrics.sampledAt = Date()
    return metrics
  }

  private func sampleApp(into metrics: inout SystemMetrics) {
    var vm = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let result = withUnsafeMutablePointer(to: &vm) {
      $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
        task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
      }
    }
    if result == KERN_SUCCESS {
      metrics.appFootprintBytes = vm.phys_footprint
      metrics.appResidentBytes = vm.resident_size
    }

    var threads: thread_act_array_t?
    var threadCount = mach_msg_type_number_t(0)
    if task_threads(mach_task_self_, &threads, &threadCount) == KERN_SUCCESS, let threads {
      metrics.appThreads = Int(threadCount)
      var total = 0.0
      for index in 0..<Int(threadCount) {
        var info = thread_basic_info()
        var infoCount = mach_msg_type_number_t(MemoryLayout<thread_basic_info>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &info) {
          $0.withMemoryRebound(to: integer_t.self, capacity: Int(infoCount)) {
            thread_info(threads[index], thread_flavor_t(THREAD_BASIC_INFO), $0, &infoCount)
          }
        }
        if status == KERN_SUCCESS, info.flags & TH_FLAGS_IDLE == 0 {
          total += Double(info.cpu_usage) / Double(TH_USAGE_SCALE) * 100
        }
        mach_port_deallocate(mach_task_self_, threads[index])
      }
      vm_deallocate(
        mach_task_self_, vm_address_t(UInt(bitPattern: threads)),
        vm_size_t(Int(threadCount) * MemoryLayout<thread_t>.size))
      metrics.appCPUPercent = total
    }
    metrics.appUptime = Date().timeIntervalSince(launchDate)

    if let device = MTLCreateSystemDefaultDevice() {
      metrics.gpuName = device.name
      metrics.gpuAllocatedBytes = UInt64(device.currentAllocatedSize)
      metrics.gpuWorkingSetBytes = device.recommendedMaxWorkingSetSize
      metrics.unifiedMemory = device.hasUnifiedMemory
    }
  }

  private func sampleMemory(into metrics: inout SystemMetrics) {
    metrics.totalMemoryBytes = ProcessInfo.processInfo.physicalMemory
    var stats = vm_statistics64_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
    let result = withUnsafeMutablePointer(to: &stats) {
      $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
        host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
      }
    }
    if result == KERN_SUCCESS {
      let page = UInt64(sysconf(_SC_PAGESIZE))
      metrics.freeBytes = UInt64(stats.free_count) * page
      metrics.wiredBytes = UInt64(stats.wire_count) * page
      metrics.compressedBytes = UInt64(stats.compressor_page_count) * page
      metrics.cachedBytes = UInt64(stats.external_page_count) * page
      let used = UInt64(stats.active_count + stats.inactive_count + stats.speculative_count
        + stats.wire_count + stats.compressor_page_count) * page
      metrics.usedMemoryBytes = min(metrics.totalMemoryBytes, used - min(used, metrics.cachedBytes))
    }
    var swap = xsw_usage()
    var size = MemoryLayout<xsw_usage>.size
    if sysctlbyname("vm.swapusage", &swap, &size, nil, 0) == 0 {
      metrics.swapUsedBytes = swap.xsu_used
      metrics.swapTotalBytes = swap.xsu_total
    }
    var level: Int32 = 0
    var levelSize = MemoryLayout<Int32>.size
    if sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &levelSize, nil, 0) == 0 {
      metrics.pressureLevel = level >= 4 ? "Critical" : level >= 2 ? "Warning" : "Normal"
    }
  }

  private func sampleCPU(into metrics: inout SystemMetrics) {
    metrics.coreCount = ProcessInfo.processInfo.activeProcessorCount
    var info = host_cpu_load_info()
    var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
    let result = withUnsafeMutablePointer(to: &info) {
      $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
        host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
      }
    }
    if result == KERN_SUCCESS {
      let current = (
        user: info.cpu_ticks.0, system: info.cpu_ticks.1, idle: info.cpu_ticks.2,
        nice: info.cpu_ticks.3
      )
      if let previous = previousTicks {
        let user = Double(current.user &- previous.user)
        let system = Double(current.system &- previous.system)
        let idle = Double(current.idle &- previous.idle)
        let nice = Double(current.nice &- previous.nice)
        let total = user + system + idle + nice
        if total > 0 {
          metrics.systemCPUPercent = (user + system + nice) / total * 100
          metrics.userCPUPercent = (user + nice) / total * 100
        }
      }
      previousTicks = current
    }
    var load = [Double](repeating: 0, count: 3)
    if getloadavg(&load, 3) == 3 { metrics.loadAverage = (load[0], load[1], load[2]) }
    metrics.systemUptime = ProcessInfo.processInfo.systemUptime
  }

  private func samplePower(into metrics: inout SystemMetrics) {
    switch ProcessInfo.processInfo.thermalState {
    case .nominal: metrics.thermalState = "Nominal"
    case .fair: metrics.thermalState = "Fair"
    case .serious: metrics.thermalState = "Serious"
    case .critical: metrics.thermalState = "Critical"
    @unknown default: metrics.thermalState = "Unknown"
    }
    metrics.lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
    let snapshot = IOPSCopyPowerSourcesInfo().takeRetainedValue()
    let sources = IOPSCopyPowerSourcesList(snapshot).takeRetainedValue() as Array
    for source in sources {
      guard
        let description = IOPSGetPowerSourceDescription(snapshot, source)?.takeUnretainedValue()
          as? [String: Any],
        let capacity = description[kIOPSCurrentCapacityKey] as? Int
      else { continue }
      metrics.batteryPercent = capacity
      metrics.onACPower = (description[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue
    }
  }

  private func sampleDisks(into metrics: inout SystemMetrics, trainingRoot: URL?) {
    let keys: Set<URLResourceKey> = [
      .volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey,
    ]
    if let values = try? URL(fileURLWithPath: "/").resourceValues(forKeys: keys) {
      metrics.systemVolumeFreeBytes = values.volumeAvailableCapacityForImportantUsage
      metrics.systemVolumeTotalBytes = values.volumeTotalCapacity.map(Int64.init)
    }
    if let trainingRoot, let values = try? trainingRoot.resourceValues(forKeys: keys) {
      metrics.trainingVolumeFreeBytes = values.volumeAvailableCapacityForImportantUsage
      metrics.trainingVolumeTotalBytes = values.volumeTotalCapacity.map(Int64.init)
    }
  }

  private func probe(name: String, url: String) async -> ServiceProbe {
    var result = ServiceProbe(name: name)
    guard let url = URL(string: url) else { return result }
    var request = URLRequest(url: url)
    request.timeoutInterval = 1.5
    let start = ContinuousClock.now
    do {
      let (_, response) = try await URLSession.shared.data(for: request)
      let elapsed = start.duration(to: .now)
      result.latencyMilliseconds =
        Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15
      let code = (response as? HTTPURLResponse)?.statusCode ?? 0
      result.isUp = code == 200
      result.detail = "HTTP \(code)"
    } catch {
      result.detail = "Not reachable"
    }
    return result
  }

  private func readMacmon() async -> HardwareReading? {
    guard let url = URL(string: "http://127.0.0.1:9090/json") else { return nil }
    var request = URLRequest(url: url)
    request.timeoutInterval = 1.5
    guard let (data, _) = try? await URLSession.shared.data(for: request),
      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return nil }
    func number(_ key: String) -> Double? { (json[key] as? NSNumber)?.doubleValue }
    let temps = json["temp"] as? [String: Any]
    let gpuUsage = json["gpu_usage"] as? [Any]
    let fans = (json["fans"] as? [[String: Any]] ?? []).compactMap { fan -> FanReading? in
      guard let rpm = (fan["rpm"] as? NSNumber)?.doubleValue else { return nil }
      return FanReading(
        name: fan["name"] as? String ?? "fan", rpm: rpm,
        maxRPM: (fan["max_rpm"] as? NSNumber)?.doubleValue ?? 0)
    }
    return HardwareReading(
      cpuTemperature: (temps?["cpu_temp_avg"] as? NSNumber)?.doubleValue,
      gpuTemperature: (temps?["gpu_temp_avg"] as? NSNumber)?.doubleValue,
      gpuUsagePercent: (gpuUsage?.last as? NSNumber).map { $0.doubleValue * 100 },
      gpuFrequencyMHz: (gpuUsage?.first as? NSNumber)?.doubleValue,
      cpuPowerWatts: number("cpu_power"), gpuPowerWatts: number("gpu_power"),
      anePowerWatts: number("ane_power"), systemWatts: number("all_power") ?? number("sys_power"),
      efficiencyFrequencyMHz: number("ecpu_freq_mhz"),
      performanceFrequencyMHz: number("pcpu_freq_mhz"),
      efficiencyUsagePercent: number("ecpu_scaled_ratio").map { $0 * 100 },
      performanceUsagePercent: number("pcpu_scaled_ratio").map { $0 * 100 },
      fans: fans)
  }
}

extension SystemMetrics {
  static func bytes(_ value: UInt64) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(clamping: value), countStyle: .memory)
  }
}


enum AlertSeverity: Int, Comparable, Sendable {
  case caution = 1
  case danger = 2

  static func < (lhs: AlertSeverity, rhs: AlertSeverity) -> Bool { lhs.rawValue < rhs.rawValue }
}

struct HealthAlert: Identifiable, Sendable {
  let id: String
  let severity: AlertSeverity
  let title: String
  let advice: String
}

/// Thresholds. Memory pressure and thermal state are macOS's own levels. Temperature, swap and
/// disk limits are conservative heuristics: Apple publishes no per-chip temperature limit.
enum HealthThresholds {
  static let tempCaution = 95.0
  static let tempDanger = 100.0
  static let sustainedSamples = 5
  static let memoryUsedCaution = 90.0
  static let swapOfRAMCaution = 0.25
  static let swapOfRAMDanger = 0.50
  static let diskFreeCautionFraction = 0.10
  static let diskFreeDangerFraction = 0.05
  static let trainingFreeCautionBytes: Int64 = 20 * 1_073_741_824
  static let trainingFreeDangerBytes: Int64 = 5 * 1_073_741_824
  static let fanCautionFraction = 0.95
  static let batteryCaution = 20
  static let stalledLogSeconds = 300.0

  static func alerts(
    metrics m: SystemMetrics, snapshot: TrainingAlertInput, history: [SystemHistoryPoint]
  ) -> [HealthAlert] {
    var result: [HealthAlert] = []
    func add(_ id: String, _ severity: AlertSeverity, _ title: String, _ advice: String) {
      result.append(HealthAlert(id: id, severity: severity, title: title, advice: advice))
    }
    func sustained(_ keyPath: KeyPath<SystemHistoryPoint, Double?>, _ limit: Double) -> Bool {
      let recent = history.suffix(sustainedSamples)
      return recent.count == sustainedSamples && recent.allSatisfy { ($0[keyPath: keyPath] ?? 0) >= limit }
    }

    for (name, value, key) in [
      ("CPU", m.hardware?.cpuTemperature, \SystemHistoryPoint.cpuTemp),
      ("GPU", m.hardware?.gpuTemperature, \SystemHistoryPoint.gpuTemp),
    ] {
      guard let value else { continue }
      if value >= tempDanger || sustained(key, tempDanger) {
        add("temp-\(name)", .danger, "\(name) at \(Int(value))°C",
          "At the thermal ceiling the chip throttles. Pause training, improve airflow, and avoid enclosed spaces.")
      } else if value >= tempCaution {
        add("temp-\(name)", .caution, "\(name) running hot (\(Int(value))°C)",
          "Common under sustained load but near the throttle point. Check airflow and consider a cooldown pause.")
      }
    }
    switch m.thermalState {
    case "Critical":
      add("thermal", .danger, "macOS thermal state: Critical", "The system is heavily throttling. Stop heavy work now.")
    case "Serious":
      add("thermal", .caution, "macOS thermal state: Serious", "macOS is reducing performance to cool down.")
    default: break
    }
    switch m.pressureLevel {
    case "Critical":
      add("pressure", .danger, "Memory pressure: Critical", "Apps may be terminated. Quit apps or stop the trainer.")
    case "Warning":
      add("pressure", .caution, "Memory pressure: Warning", "The Mac is compressing and swapping heavily. Close other apps.")
    default: break
    }
    if m.memoryUsedPercent >= memoryUsedCaution {
      add("memory", .caution, "Memory \(Int(m.memoryUsedPercent))% used", "Little headroom is left for the app and model loads.")
    }
    if m.totalMemoryBytes > 0 {
      let swapRatio = Double(m.swapUsedBytes) / Double(m.totalMemoryBytes)
      if swapRatio >= swapOfRAMDanger {
        add("swap", .danger, "Swap is \(Int(swapRatio * 100))% of RAM",
          "Heavy swapping slows training and adds sustained SSD writes. Free memory or lower the batch or sequence length.")
      } else if swapRatio >= swapOfRAMCaution {
        add("swap", .caution, "Swap is \(Int(swapRatio * 100))% of RAM",
          "Training is spilling to disk. Close other apps to keep it fast.")
      }
    }
    if let free = m.systemVolumeFreeBytes, let total = m.systemVolumeTotalBytes, total > 0 {
      let fraction = Double(free) / Double(total)
      if fraction < diskFreeDangerFraction {
        add("disk", .danger, "Startup disk almost full", "macOS needs free space for swap. Free space immediately.")
      } else if fraction < diskFreeCautionFraction {
        add("disk", .caution, "Startup disk under 10% free", "Low space limits swap and caches.")
      }
    }
    if let free = m.trainingVolumeFreeBytes {
      if free < trainingFreeDangerBytes {
        add("train-disk", .danger, "Training drive nearly full", "Checkpoint saves may fail and corrupt a run. Free space now.")
      } else if free < trainingFreeCautionBytes {
        add("train-disk", .caution, "Training drive under 20 GB free", "Each checkpoint adds data. Free space before the next save.")
      }
    }
    for fan in m.hardware?.fans ?? [] where fan.maxRPM > 0 && fan.rpm / fan.maxRPM >= fanCautionFraction {
      add("fan-\(fan.name)", .caution, "\(fan.name) at maximum speed", "Cooling is saturated. Check for blocked vents.")
    }
    if let battery = m.batteryPercent, !m.onACPower, battery <= batteryCaution {
      add("battery", .caution, "Battery at \(battery)% on battery power", "Plug in before long training or inference.")
    }
    if snapshot.trainerRunning, let age = snapshot.logAge, age > stalledLogSeconds {
      add("stalled", .danger, "Trainer log silent for \(Int(age / 60)) min",
        "The trainer may be stalled or hung. Check train log and the watchdog before restarting.")
    }
    return result.sorted { $0.severity > $1.severity }
  }
}

struct TrainingAlertInput: Sendable {
  var trainerRunning: Bool
  var logAge: TimeInterval?
}
