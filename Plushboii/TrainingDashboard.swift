import AppKit
import Charts
import Darwin
import Foundation
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
  var isEvaluating: Bool { evaluationPID != nil }
  var isBusy: Bool { isTraining || isEvaluating }
}

private struct TrainingProcess: Sendable {
  let pid: Int32
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

    do {
      let processes = try processList()
      let python = root.appending(path: "venv/bin/python").path
      let trainScript = root.appending(path: "run_train.py").path
      let evaluationScript = root.appending(path: "eval_cuts3.py").path
      let serverScript = root.appending(path: "run_server.py").path
      let training = processes.first {
        $0.command.contains(python) && $0.command.contains(trainScript)
      }
      let evaluation = processes.first {
        $0.command.contains(python) && $0.command.contains(evaluationScript)
      }
      let server = processes.first {
        $0.command.contains(python) && $0.command.contains(serverScript)
      }
      result.trainingPID = training?.pid
      result.evaluationPID = evaluation?.pid
      result.serverPID = server?.pid

      if let capacity = try? root.resourceValues(forKeys: [.volumeAvailableCapacityKey])
        .volumeAvailableCapacity
      {
        result.availableBytes = Int64(capacity)
      }
      result.trainingSamples = lineCount(at: root.appending(path: "anatomy3/train.jsonl"))
      result.validationSamples = lineCount(at: root.appending(path: "anatomy3/valid.jsonl"))
      readAutomationReports(in: root, into: &result)

      if let logURL = trainingLog(for: training?.command, in: root) {
        parseTrainingLog(at: logURL, into: &result)
      }
      if let evaluationLog = newestLog(prefix: "eval_dashboard_", in: root) {
        result.evaluationSummary = lastEvaluationSummary(at: evaluationLog)
        result.evaluationProgress = lastEvaluationProgress(at: evaluationLog)
      }

      let adapter = newestAdapter(in: root)
      result.adapterPath = adapter?.path
      result.checkpointCount = adapter.map(checkpointCount(in:)) ?? 0
    } catch {
      result.errorMessage = error.localizedDescription
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
    process.arguments = ["-axo", "pid=,command="]
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
          maxSplits: 1, omittingEmptySubsequences: true, whereSeparator: \.isWhitespace)
        guard columns.count == 2, let pid = Int32(columns[0]) else { return nil }
        return TrainingProcess(pid: pid, command: String(columns[1]))
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
      try handle.seek(toOffset: end > 1_000_000 ? end - 1_000_000 : 0)
      let text = String(decoding: try handle.readToEnd() ?? Data(), as: UTF8.self)
        .replacingOccurrences(of: "\r", with: "\n")
      let progress = try NSRegularExpression(
        pattern: #"(\d+)/(\d+)\s+\[[^<]*<([^,]+),\s*([0-9.]+)s/it,\s*loss=([0-9.]+)"#
      )
      for line in text.split(whereSeparator: \.isNewline) {
        let lineString = String(line)
        if let match = progress.firstMatch(
          in: lineString,
          range: NSRange(lineString.startIndex..., in: lineString)
        ), match.numberOfRanges == 6,
          let step = integer(in: lineString, range: match.range(at: 1)),
          let total = integer(in: lineString, range: match.range(at: 2)),
          let loss = double(in: lineString, range: match.range(at: 5))
        {
          snapshot.trainingStep = step
          snapshot.totalSteps = total
          snapshot.trainingLoss = loss
          snapshot.estimatedSecondsRemaining = seconds(in: lineString, range: match.range(at: 3))
          snapshot.trainingLosses.append(TrainingMetricPoint(step: step, value: loss))
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
      snapshot.trainingLosses = Array(snapshot.trainingLosses.suffix(100))
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
  @Environment(\.dismiss) private var dismiss
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

  private let bookmarkKey = "trainingDashboard.folderBookmark"

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        VStack(alignment: .leading, spacing: 4) {
          Text("Training Dashboard")
            .font(.title2.weight(.semibold))
          Text("Monitor MLX training, validation, model outputs, and the training drive.")
            .foregroundStyle(.secondary)
        }
        Spacer()
        Button("Done") { dismiss() }
          .keyboardShortcut(.defaultAction)
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
                    : snapshot.isDriveMounted ? "Drive connected" : "Drive unavailable"
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

          GroupBox("Run status") {
            HStack {
              statusIndicator
              Spacer()
              Text("Updated \(snapshot.updatedAt, style: .time)")
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            if let step = snapshot.trainingStep, let total = snapshot.totalSteps, total > 0 {
              ProgressView(value: Double(step), total: Double(total))
              HStack {
                Text("Step \(step.formatted()) of \(total.formatted())")
                Spacer()
                if let remaining = snapshot.estimatedSecondsRemaining {
                  Text("ETA \(remaining.formattedDuration)")
                    .foregroundStyle(.secondary)
                }
              }
              .font(.caption)
            }
            HStack {
              LabeledContent("Training", value: snapshot.trainingPID.map { "PID \($0)" } ?? "Idle")
              LabeledContent(
                "Validation", value: snapshot.evaluationPID.map { "PID \($0)" } ?? "Idle")
              LabeledContent(
                "MLX server", value: snapshot.serverPID.map { "PID \($0)" } ?? "Stopped")
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
                    ?? "—")
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
                    "\(snapshot.trainingSamples.formatted()) train · \(snapshot.validationSamples.formatted()) validation"
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
                trainingFolder == nil || snapshot.isBusy || snapshot.serverPID != nil
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
                trainingFolder == nil || snapshot.isBusy || snapshot.adapterPath == nil
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
                trainingFolder == nil || snapshot.serverPID != nil || snapshot.isBusy
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
        try? await Task.sleep(for: .seconds(5))
        if Task.isCancelled { break }
        await refreshSnapshot()
      }
    }
    .onDisappear {
      if securityScopeActive, let trainingFolder {
        trainingFolder.stopAccessingSecurityScopedResource()
      }
    }
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
    guard let bookmark = UserDefaults.standard.data(forKey: bookmarkKey) else { return }
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
