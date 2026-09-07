import SwiftUI
import UniformTypeIdentifiers
import VHOSCore

struct MechanicWorkspaceView: View {
  @State private var workspace = MechanicWorkspaceModel()
  @State private var searchText = ""
  @State private var showingIntake = false
  @State private var showingVoided = false

  private var visibleCases: [MechanicDiagnosticCaseRevision] {
    workspace.cases.filter { item in
      let matchesState = showingVoided || item.status != .voided
      let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
      let matchesQuery =
        query.isEmpty
        || item.vehicle.displayName.localizedCaseInsensitiveContains(query)
        || item.customer.displayName.localizedCaseInsensitiveContains(query)
        || item.complaint.description.localizedCaseInsensitiveContains(query)
        || item.caseID.localizedCaseInsensitiveContains(query)
      return matchesState && matchesQuery
    }
  }

  var body: some View {
    List {
      authorityBanner
      switch workspace.loadState {
      case .unavailable(let detail):
        ContentUnavailableView(
          "Case ledger unavailable",
          systemImage: "exclamationmark.lock.fill",
          description: Text("\(detail) No case data can be changed until integrity is restored."))
      case .ready, .recoveredInterruptedWrite:
        if visibleCases.isEmpty {
          ContentUnavailableView {
            Label(
              searchText.isEmpty ? "No diagnostic cases" : "No matching cases",
              systemImage: "wrench.and.screwdriver")
          } description: {
            Text(
              searchText.isEmpty
                ? "Create a real customer case. This workspace never inserts sample vehicle data."
                : "Try another vehicle, customer, concern, or case ID.")
          } actions: {
            if searchText.isEmpty {
              Button("Create first case") { showingIntake = true }
                .buttonStyle(.borderedProminent)
            }
          }
        } else {
          Section {
            ForEach(visibleCases) { item in
              NavigationLink(value: item.caseID) {
                MechanicCaseRow(revision: item)
              }
            }
          } header: {
            HStack {
              Text(showingVoided ? "All local cases" : "Active and closed")
              Spacer()
              Text("\(visibleCases.count)")
            }
          }
        }
      }
    }
    .navigationTitle("Cases")
    .navigationDestination(for: String.self) { caseID in
      MechanicCaseDetailView(workspace: workspace, caseID: caseID)
    }
    .searchable(text: $searchText, prompt: "Vehicle, customer, concern, case ID")
    .toolbar {
      ToolbarItem(placement: .topBarLeading) {
        Toggle(isOn: $showingVoided) {
          Label("Voided", systemImage: "archivebox")
        }
        .toggleStyle(.button)
      }
      ToolbarItem(placement: .topBarTrailing) {
        Button("New case", systemImage: "plus") { showingIntake = true }
          .disabled(!workspace.loadState.allowsMutation)
      }
    }
    .sheet(isPresented: $showingIntake) {
      NavigationStack {
        MechanicCaseIntakeView(workspace: workspace) {
          showingIntake = false
        }
      }
    }
    .safeAreaInset(edge: .bottom) {
      if let error = workspace.operationError {
        WorkspaceMessage(text: error, isError: true) { workspace.operationError = nil }
      } else if let message = workspace.operationMessage {
        WorkspaceMessage(text: message, isError: false) { workspace.operationMessage = nil }
      }
    }
  }

  @ViewBuilder private var authorityBanner: some View {
    Section {
      Label {
        VStack(alignment: .leading, spacing: 4) {
          Text("Technician local drafts")
            .font(.headline)
          Text("Not canonical service history and not vehicle safety clearance.")
            .font(.caption)
        }
      } icon: {
        Image(systemName: "person.badge.shield.checkmark")
          .foregroundStyle(.orange)
      }
      if case .recoveredInterruptedWrite(let detail) = workspace.loadState {
        Label(detail, systemImage: "cross.case.fill")
          .font(.caption)
          .foregroundStyle(.orange)
      }
    }
  }
}

private struct MechanicCaseRow: View {
  let revision: MechanicDiagnosticCaseRevision

  var body: some View {
    VStack(alignment: .leading, spacing: 7) {
      HStack {
        Text(revision.vehicle.displayName)
          .font(.headline)
        Spacer()
        CaseStatusBadge(status: revision.status)
      }
      Text(revision.complaint.description)
        .font(.subheadline)
        .lineLimit(2)
      HStack {
        Label(revision.customer.displayName, systemImage: "person")
        Spacer()
        Text("r\(revision.revisionNumber)")
        Text(Self.formatted(revision.createdAt))
      }
      .font(.caption)
      .foregroundStyle(.secondary)
    }
    .padding(.vertical, 4)
  }

  private static func formatted(_ value: String) -> String {
    guard let date = ISO8601DateFormatter().date(from: value) else { return value }
    return date.formatted(date: .abbreviated, time: .shortened)
  }
}

private struct CaseStatusBadge: View {
  let status: MechanicDiagnosticCaseStatus

  private var color: Color {
    switch status {
    case .intake: .blue
    case .inspection: .indigo
    case .findings: .purple
    case .verify: .orange
    case .closed: .green
    case .voided: .secondary
    }
  }

  var body: some View {
    Text(status.displayName.uppercased())
      .font(.caption2.bold())
      .foregroundStyle(color)
      .padding(.horizontal, 8)
      .padding(.vertical, 4)
      .background(color.opacity(0.12), in: Capsule())
  }
}

private struct MechanicCaseIntakeView: View {
  let workspace: MechanicWorkspaceModel
  let didSave: () -> Void
  @Environment(\.dismiss) private var dismiss
  @State private var draft = MechanicCaseIntakeDraft()

  var body: some View {
    Form {
      Section("Technician") {
        TextField("Business or organization", text: $draft.organizationName)
        TextField("Technician name", text: $draft.technicianName)
      }
      Section("Customer") {
        TextField("Customer or referring shop", text: $draft.customerName)
        TextField("Phone (optional)", text: $draft.customerPhone)
          .keyboardType(.phonePad)
        TextField("Email (optional)", text: $draft.customerEmail)
          .keyboardType(.emailAddress)
          .textInputAutocapitalization(.never)
          .autocorrectionDisabled()
        Text("Contact details stay on this device unless deliberately included in a report.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      Section("Vehicle — record only what is known") {
        TextField("Vehicle label (required)", text: $draft.vehicleDisplayName)
        TextField("VIN (optional)", text: $draft.vin)
          .textInputAutocapitalization(.characters)
          .autocorrectionDisabled()
        TextField("Model year", text: $draft.modelYear)
          .keyboardType(.numberPad)
        TextField("Make", text: $draft.make)
        TextField("Model", text: $draft.model)
        TextField("Trim", text: $draft.trim)
        TextField("License plate", text: $draft.licensePlate)
          .textInputAutocapitalization(.characters)
        HStack {
          TextField("Odometer", text: $draft.odometer)
            .keyboardType(.numberPad)
          Picker("Unit", selection: $draft.odometerUnit) {
            Text("mi").tag(MechanicDiagnosticDistanceUnit.miles)
            Text("km").tag(MechanicDiagnosticDistanceUnit.kilometers)
          }
          .labelsHidden()
        }
      }
      Section("Concern") {
        Picker("Reported by", selection: $draft.reporter) {
          ForEach(
            [
              MechanicDiagnosticComplaintReporter.customer,
              .referringShop,
              .technician,
            ], id: \.self
          ) { reporter in
            Text(reporter.displayName).tag(reporter)
          }
        }
        LabeledTextEditor(title: "Customer concern", text: $draft.concern, minimumHeight: 100)
        LabeledTextEditor(
          title: "Operating conditions (optional)", text: $draft.operatingConditions)
        LabeledTextEditor(title: "Prior work (optional)", text: $draft.priorWork)
      }
      Section {
        Label(
          "Saving creates immutable revision 1 with TECHNICIAN_LOCAL_DRAFT authority.",
          systemImage: "lock.doc"
        )
        .font(.caption)
        .foregroundStyle(.secondary)
      }
    }
    .navigationTitle("Intake")
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItem(placement: .cancellationAction) {
        Button("Cancel") { dismiss() }
      }
      ToolbarItem(placement: .confirmationAction) {
        Button("Save") { save() }
          .fontWeight(.semibold)
      }
    }
  }

  private func save() {
    do {
      _ = try workspace.createCase(from: draft)
      didSave()
    } catch {
      workspace.operationError = error.localizedDescription
    }
  }
}

private struct MechanicCaseDetailView: View {
  let workspace: MechanicWorkspaceModel
  let caseID: String
  @State private var showingVoid = false
  @State private var voidReason = ""

  private var revision: MechanicDiagnosticCaseRevision? {
    workspace.caseRevision(caseID)
  }

  var body: some View {
    Group {
      if let revision {
        List {
          Section {
            HStack {
              CaseStatusBadge(status: revision.status)
              Spacer()
              Text("Revision \(revision.revisionNumber)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            }
            CaseProgressView(status: revision.status)
          }
          Section("Intake") {
            LabeledContent("Customer", value: revision.customer.displayName)
            LabeledContent("Vehicle", value: revision.vehicle.displayName)
            if let odometer = revision.vehicle.odometer {
              LabeledContent(
                "Odometer",
                value: "\(odometer.value.formatted()) \(odometer.unit == .miles ? "mi" : "km")")
            }
            VStack(alignment: .leading, spacing: 5) {
              Text("Concern").font(.caption).foregroundStyle(.secondary)
              Text(revision.complaint.description)
            }
            if let conditions = revision.complaint.operatingConditions {
              VStack(alignment: .leading, spacing: 5) {
                Text("Operating conditions").font(.caption).foregroundStyle(.secondary)
                Text(conditions)
              }
            }
          }
          Section("Workflow") {
            if revision.status == .intake {
              Button {
                perform { try workspace.startInspection(caseID: caseID) }
              } label: {
                Label("Start inspection", systemImage: "play.circle.fill")
              }
              .buttonStyle(.borderedProminent)
            }
            NavigationLink {
              MechanicEvidenceView(workspace: workspace, caseID: caseID)
            } label: {
              WorkflowLinkLabel(
                title: "Evidence",
                detail: "\(revision.evidence.count) recorded items",
                image: "doc.text.magnifyingglass")
            }
            .disabled(revision.status == .intake || revision.status == .voided)
            NavigationLink {
              MechanicAssessmentView(workspace: workspace, caseID: caseID)
            } label: {
              WorkflowLinkLabel(
                title: "Findings",
                detail: "\(revision.hypotheses.count) hypotheses",
                image: "point.3.connected.trianglepath.dotted")
            }
            .disabled(revision.status == .intake || revision.status == .voided)
            NavigationLink {
              MechanicReportView(workspace: workspace, caseID: caseID)
            } label: {
              WorkflowLinkLabel(
                title: "Verification & report",
                detail: revision.finding == nil ? "Finding required" : "Generate from exact revision",
                image: "doc.richtext")
            }
            .disabled(
              revision.status == .intake || revision.status == .inspection
                || revision.status == .voided)
          }
          Section("Authority") {
            Label("Technician local draft", systemImage: "person.badge.shield.checkmark")
            Label("Not an authorized vehicle finding", systemImage: "xmark.shield")
            Label(
              "Does not change maintenance history",
              systemImage: "arrow.trianglehead.2.clockwise.rotate.90")
          }
          .font(.footnote)
          if revision.status != .voided {
            Section {
              Button("Void case", role: .destructive) { showingVoid = true }
            } footer: {
              Text("Voiding appends a reasoned tombstone. It does not erase case history.")
            }
          }
        }
        .navigationTitle(revision.vehicle.displayName)
      } else {
        ContentUnavailableView("Case unavailable", systemImage: "questionmark.folder")
      }
    }
    .alert("Void this case?", isPresented: $showingVoid) {
      TextField("Reason", text: $voidReason)
      Button("Void", role: .destructive) {
        perform { try workspace.voidCase(caseID: caseID, reason: voidReason) }
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("The full revision chain remains on this device.")
    }
  }

  private func perform(_ operation: () throws -> Void) {
    do { try operation() } catch { workspace.operationError = error.localizedDescription }
  }
}

private struct WorkflowLinkLabel: View {
  let title: String
  let detail: String
  let image: String

  var body: some View {
    Label {
      VStack(alignment: .leading) {
        Text(title)
        Text(detail).font(.caption).foregroundStyle(.secondary)
      }
    } icon: {
      Image(systemName: image).foregroundStyle(.tint)
    }
  }
}

private struct CaseProgressView: View {
  let status: MechanicDiagnosticCaseStatus
  private let steps: [MechanicDiagnosticCaseStatus] = [
    .intake, .inspection, .findings, .verify, .closed,
  ]

  var body: some View {
    HStack(spacing: 5) {
      ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
        Capsule()
          .fill(fill(step))
          .frame(height: 5)
          .accessibilityLabel(step.displayName)
          .accessibilityValue(index <= activeIndex ? "Complete or current" : "Upcoming")
      }
    }
  }

  private var activeIndex: Int {
    status == .voided ? -1 : steps.firstIndex(of: status) ?? -1
  }

  private func fill(_ step: MechanicDiagnosticCaseStatus) -> Color {
    guard let index = steps.firstIndex(of: step), index <= activeIndex else {
      return .secondary.opacity(0.2)
    }
    return status == .voided ? .secondary : .accentColor
  }
}

private struct MechanicEvidenceView: View {
  let workspace: MechanicWorkspaceModel
  let caseID: String
  @State private var showingEvidence = false
  @State private var showingAttachment = false

  private var revision: MechanicDiagnosticCaseRevision? { workspace.caseRevision(caseID) }

  var body: some View {
    List {
      Section {
        Label(
          "Facts stay distinct from hypotheses. Missing data is never treated as a healthy result.",
          systemImage: "checkmark.seal.text.page"
        )
        .font(.footnote)
      }
      if let revision, revision.evidence.isEmpty {
        ContentUnavailableView(
          "No evidence recorded",
          systemImage: "tray",
          description: Text("Add an observation, measurement, DTC fact, or durable attachment."))
      } else if let revision {
        ForEach(revision.evidence) { item in
          Section {
            VStack(alignment: .leading, spacing: 8) {
              HStack {
                Label(item.type.displayName, systemImage: icon(item.type))
                  .font(.headline)
                Spacer()
                Text(item.quality.displayName.uppercased())
                  .font(.caption2.bold())
                  .foregroundStyle(item.quality == .verified ? .green : .orange)
              }
              Text(item.description)
              if let value = item.value {
                LabeledContent(
                  "Value", value: [value, item.unit].compactMap { $0 }.joined(separator: " "))
              }
              if let code = item.dtcCode { LabeledContent("DTC", value: code) }
              if let method = item.method { LabeledContent("Method", value: method) }
              if let expected = item.expectedResult {
                LabeledContent("Expected", value: expected)
              }
              LabeledContent("Source", value: item.source.displayName)
                .font(.caption)
                .foregroundStyle(.secondary)
            }
          }
        }
      }
    }
    .navigationTitle("Evidence")
    .toolbar {
      ToolbarItem(placement: .topBarTrailing) {
        Menu {
          Button("Record fact", systemImage: "square.and.pencil") { showingEvidence = true }
          Button("Import durable attachment", systemImage: "paperclip") {
            showingAttachment = true
          }
        } label: {
          Label("Add evidence", systemImage: "plus")
        }
        .disabled(revision?.status == .closed || revision?.status == .voided)
      }
    }
    .sheet(isPresented: $showingEvidence) {
      NavigationStack {
        MechanicEvidenceEditor(workspace: workspace, caseID: caseID) {
          showingEvidence = false
        }
      }
    }
    .sheet(isPresented: $showingAttachment) {
      NavigationStack {
        MechanicAttachmentEditor(workspace: workspace, caseID: caseID) {
          showingAttachment = false
        }
      }
    }
  }

  private func icon(_ type: MechanicDiagnosticEvidenceType) -> String {
    switch type {
    case .observation: "eye"
    case .measurement: "ruler"
    case .dtc: "exclamationmark.square"
    case .photo: "photo"
    case .video: "video"
    case .audio: "waveform"
    case .document: "doc"
    case .scanReport: "scanner"
    }
  }
}

private struct MechanicAttachmentEditor: View {
  let workspace: MechanicWorkspaceModel
  let caseID: String
  let didSave: () -> Void
  @Environment(\.dismiss) private var dismiss
  @State private var type: MechanicDiagnosticEvidenceType = .document
  @State private var description = ""
  @State private var selectedURL: URL?
  @State private var importing = false

  var body: some View {
    Form {
      Section("Attachment") {
        Picker("Kind", selection: $type) {
          Text("Photo").tag(MechanicDiagnosticEvidenceType.photo)
          Text("Video").tag(MechanicDiagnosticEvidenceType.video)
          Text("Audio").tag(MechanicDiagnosticEvidenceType.audio)
          Text("Document").tag(MechanicDiagnosticEvidenceType.document)
          Text("Scan report").tag(MechanicDiagnosticEvidenceType.scanReport)
        }
        Button(selectedURL == nil ? "Choose file" : "Choose a different file") {
          importing = true
        }
        if let selectedURL {
          Label(selectedURL.lastPathComponent, systemImage: "doc.fill")
            .font(.footnote)
        }
        LabeledTextEditor(
          title: "What does this file show?",
          text: $description,
          minimumHeight: 90)
      }
      Section {
        Label(
          "The app copies and SHA-256 verifies up to 25 MiB in private storage before committing its evidence reference.",
          systemImage: "lock.doc"
        )
        .font(.caption)
        .foregroundStyle(.secondary)
      }
    }
    .navigationTitle("Import evidence")
    .navigationBarTitleDisplayMode(.inline)
    .fileImporter(
      isPresented: $importing,
      allowedContentTypes: [.image, .movie, .audio, .pdf, .plainText, .data],
      allowsMultipleSelection: false
    ) { result in
      switch result {
      case .success(let urls): selectedURL = urls.first
      case .failure(let error): workspace.operationError = error.localizedDescription
      }
    }
    .toolbar {
      ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
      ToolbarItem(placement: .confirmationAction) {
        Button("Copy & commit") { save() }
          .disabled(
            selectedURL == nil
              || description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      }
    }
  }

  private func save() {
    guard let selectedURL else { return }
    let contentType = UTType(filenameExtension: selectedURL.pathExtension)
    let mediaType = contentType?.preferredMIMEType ?? "application/octet-stream"
    do {
      try workspace.importAttachmentEvidence(
        from: selectedURL,
        mediaType: mediaType,
        type: type,
        description: description,
        caseID: caseID)
      didSave()
    } catch {
      workspace.operationError = error.localizedDescription
    }
  }
}

private struct MechanicEvidenceEditor: View {
  let workspace: MechanicWorkspaceModel
  let caseID: String
  let didSave: () -> Void
  @Environment(\.dismiss) private var dismiss
  @State private var draft = MechanicEvidenceDraft()

  var body: some View {
    Form {
      Section("Evidence kind") {
        Picker("Type", selection: $draft.type) {
          Text("Observation").tag(MechanicDiagnosticEvidenceType.observation)
          Text("Measurement").tag(MechanicDiagnosticEvidenceType.measurement)
          Text("DTC fact").tag(MechanicDiagnosticEvidenceType.dtc)
        }
        Picker("Source", selection: $draft.source) {
          ForEach(MechanicDiagnosticEvidenceSource.allCases, id: \.self) { source in
            Text(source.displayName).tag(source)
          }
        }
        Picker("Quality", selection: $draft.quality) {
          ForEach(MechanicDiagnosticEvidenceQuality.allCases, id: \.self) { quality in
            Text(quality.displayName).tag(quality)
          }
        }
      }
      Section("What was recorded") {
        LabeledTextEditor(title: "Description", text: $draft.description, minimumHeight: 90)
        if draft.type == .measurement {
          TextField("Numeric value", text: $draft.value)
            .keyboardType(.numbersAndPunctuation)
          TextField("Unit", text: $draft.unit)
          TextField("Method or instrument", text: $draft.method)
          TextField("Test point (optional)", text: $draft.testPoint)
          TextField("Expected result (optional)", text: $draft.expectedResult)
          TextField("Expected-result source (optional)", text: $draft.expectedResultSource)
        } else if draft.type == .dtc {
          TextField("DTC, for example P0301", text: $draft.dtcCode)
            .textInputAutocapitalization(.characters)
            .autocorrectionDisabled()
        }
      }
      Section {
        Text(
          "Specifications and expected values are never invented. If you enter one, record its source."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
      }
    }
    .navigationTitle("Add evidence")
    .navigationBarTitleDisplayMode(.inline)
    .onChange(of: draft.type) { _, type in
      switch type {
      case .measurement:
        draft.source = .technicianMeasured
        draft.dtcCode = ""
      case .dtc:
        draft.source = .technicianObserved
        clearMeasurementFields()
      case .observation:
        draft.source = .technicianObserved
        draft.dtcCode = ""
        clearMeasurementFields()
      case .photo, .video, .audio, .document, .scanReport:
        break
      }
    }
    .toolbar {
      ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
      ToolbarItem(placement: .confirmationAction) {
        Button("Commit") {
          do {
            try workspace.addEvidence(draft, caseID: caseID)
            didSave()
          } catch { workspace.operationError = error.localizedDescription }
        }
      }
    }
  }

  private func clearMeasurementFields() {
    draft.value = ""
    draft.unit = ""
    draft.method = ""
    draft.testPoint = ""
    draft.expectedResult = ""
    draft.expectedResultSource = ""
  }
}

private struct MechanicAssessmentView: View {
  let workspace: MechanicWorkspaceModel
  let caseID: String
  @State private var showingHypothesis = false
  @State private var showingFinding = false

  private var revision: MechanicDiagnosticCaseRevision? { workspace.caseRevision(caseID) }

  var body: some View {
    List {
      if let revision {
        Section("Technician hypotheses") {
          if revision.hypotheses.isEmpty {
            Text(
              "No hypotheses recorded. A hypothesis must link to evidence as supporting, contradicting, or unknown."
            )
            .foregroundStyle(.secondary)
          }
          ForEach(revision.hypotheses) { hypothesis in
            VStack(alignment: .leading, spacing: 8) {
              Label(hypothesis.statement, systemImage: "questionmark.diamond")
                .font(.headline)
              ForEach(hypothesis.evidenceLinks, id: \.evidenceID) { link in
                HStack {
                  Text(link.relationship.displayName)
                    .font(.caption.bold())
                  Text(evidenceDescription(link.evidenceID, in: revision))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                }
              }
            }
          }
          Button("Add evidence-linked hypothesis", systemImage: "plus") {
            showingHypothesis = true
          }
          .disabled(revision.status != .inspection || revision.evidence.isEmpty)
        }
        Section("Technician finding") {
          if let finding = revision.finding {
            VStack(alignment: .leading, spacing: 9) {
              Text(finding.conclusion)
              if !finding.limitations.isEmpty {
                Label(
                  finding.limitations.joined(separator: "\n"),
                  systemImage: "exclamationmark.triangle"
                )
                .font(.footnote)
                .foregroundStyle(.orange)
              }
              Label(finding.nextAction, systemImage: "arrow.forward.circle")
                .font(.subheadline)
            }
          } else {
            Text(
              "No finding recorded. Conclusions remain technician-authored and may explicitly describe uncertainty."
            )
            .foregroundStyle(.secondary)
          }
          if revision.status == .inspection || revision.status == .findings {
            Button(revision.finding == nil ? "Record finding" : "Amend finding") {
              showingFinding = true
            }
          }
          if revision.status == .findings {
            Button("Begin verification") {
              perform { try workspace.startVerification(caseID: caseID) }
            }
            .buttonStyle(.borderedProminent)
          }
        }
        Section {
          Label(
            "Hypotheses and findings are technician assertions, not VHOS-authorized vehicle truth or safety clearance.",
            systemImage: "shield.slash"
          )
          .font(.footnote)
        }
      }
    }
    .navigationTitle("Findings")
    .sheet(isPresented: $showingHypothesis) {
      NavigationStack {
        if let revision {
          MechanicHypothesisEditor(workspace: workspace, revision: revision) {
            showingHypothesis = false
          }
        }
      }
    }
    .sheet(isPresented: $showingFinding) {
      NavigationStack {
        MechanicFindingEditor(workspace: workspace, caseID: caseID) {
          showingFinding = false
        }
      }
    }
  }

  private func evidenceDescription(
    _ evidenceID: String,
    in revision: MechanicDiagnosticCaseRevision
  ) -> String {
    revision.evidence.first(where: { $0.evidenceID == evidenceID })?.description
      ?? "Missing evidence reference"
  }

  private func perform(_ operation: () throws -> Void) {
    do { try operation() } catch { workspace.operationError = error.localizedDescription }
  }
}

private struct MechanicHypothesisEditor: View {
  let workspace: MechanicWorkspaceModel
  let revision: MechanicDiagnosticCaseRevision
  let didSave: () -> Void
  @Environment(\.dismiss) private var dismiss
  @State private var draft = MechanicHypothesisDraft()

  var body: some View {
    Form {
      Section("Hypothesis") {
        LabeledTextEditor(
          title: "What may explain the concern?", text: $draft.statement, minimumHeight: 100)
      }
      Section("Evidence relationship") {
        ForEach(revision.evidence) { evidence in
          VStack(alignment: .leading, spacing: 8) {
            Text(evidence.description).lineLimit(2)
            Picker(
              "Relationship",
              selection: Binding<MechanicDiagnosticEvidenceRelationship?>(
                get: { draft.relationships[evidence.evidenceID] },
                set: { relationship in
                  if let relationship {
                    draft.relationships[evidence.evidenceID] = relationship
                  } else {
                    draft.relationships.removeValue(forKey: evidence.evidenceID)
                  }
                })
            ) {
              Text("Not linked").tag(nil as MechanicDiagnosticEvidenceRelationship?)
              ForEach(MechanicDiagnosticEvidenceRelationship.allCases, id: \.self) { relation in
                Text(relation.displayName).tag(Optional(relation))
              }
            }
            .pickerStyle(.segmented)
          }
        }
      }
    }
    .navigationTitle("New hypothesis")
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
      ToolbarItem(placement: .confirmationAction) {
        Button("Commit") {
          do {
            try workspace.addHypothesis(draft, caseID: revision.caseID)
            didSave()
          } catch { workspace.operationError = error.localizedDescription }
        }
      }
    }
  }
}

private struct MechanicFindingEditor: View {
  let workspace: MechanicWorkspaceModel
  let caseID: String
  let didSave: () -> Void
  @Environment(\.dismiss) private var dismiss
  @State private var draft = MechanicFindingDraft()

  var body: some View {
    Form {
      Section("Technician conclusion") {
        LabeledTextEditor(
          title: "Conclusion or current best-supported assessment", text: $draft.conclusion,
          minimumHeight: 110)
        LabeledTextEditor(title: "Limitations — one per line", text: $draft.limitations)
        LabeledTextEditor(
          title: "Recommended next action", text: $draft.nextAction, minimumHeight: 80)
      }
      Section {
        Text(
          "Use limitations to preserve uncertainty, missing tests, and conditions that could not be reproduced."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
      }
    }
    .navigationTitle("Technician finding")
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
      ToolbarItem(placement: .confirmationAction) {
        Button("Commit") {
          do {
            try workspace.recordFinding(draft, caseID: caseID)
            didSave()
          } catch { workspace.operationError = error.localizedDescription }
        }
      }
    }
  }
}

private struct MechanicReportView: View {
  let workspace: MechanicWorkspaceModel
  let caseID: String
  @State private var verification = MechanicVerificationDraft()
  @State private var privacy = MechanicReportPrivacySelection()

  private var revision: MechanicDiagnosticCaseRevision? { workspace.caseRevision(caseID) }

  var body: some View {
    List {
      if let revision {
        Section {
          Label("TECHNICIAN LOCAL DRAFT", systemImage: "person.badge.shield.checkmark")
            .font(.headline)
            .foregroundStyle(.orange)
          Text(
            "This report is not vehicle safety clearance and does not change canonical maintenance history."
          )
          .font(.footnote)
        }
        if let finding = revision.finding {
          Section("Finding preview") {
            Text(finding.conclusion)
            LabeledContent("Next action", value: finding.nextAction)
          }
        }
        if revision.status == .findings {
          Section {
            Button("Begin verification") {
              perform { try workspace.startVerification(caseID: caseID) }
            }
            .buttonStyle(.borderedProminent)
          }
        } else if revision.status == .verify {
          verificationForm(revision)
        } else if let result = revision.verification {
          Section("Verification") {
            LabeledContent("Outcome", value: result.outcome.displayName)
            if let method = result.method { LabeledContent("Method", value: method) }
            if let reason = result.reason { LabeledContent("Reason", value: reason) }
          }
        }
        Section("Report artifacts") {
          Toggle("Redact customer contact", isOn: $privacy.redactCustomerContact)
          Toggle("Redact VIN", isOn: $privacy.redactVIN)
          Toggle("Redact license plate", isOn: $privacy.redactLicensePlate)
          Toggle("Redact prior-work notes", isOn: $privacy.redactPriorWork)
          Text(
            "A PDF, privacy-selected case JSON, and checksum manifest are bound to the exact committed source revision without changing it."
          )
          .font(.footnote)
          .foregroundStyle(.secondary)
          Button("Generate report", systemImage: "doc.badge.gearshape") {
            perform { _ = try workspace.prepareReport(caseID: caseID, privacy: privacy) }
          }
          .disabled(revision.finding == nil)
          if let bundle = workspace.preparedReports[revision.revisionID],
            bundle.manifest.privacy == privacy
          {
            Label(
              "Checksum manifest ready for revision \(revision.revisionNumber)",
              systemImage: "checkmark.seal.fill"
            )
            .font(.footnote)
            .foregroundStyle(.green)
            ShareLink(item: bundle.pdfURL) {
              Label("Share customer PDF", systemImage: "square.and.arrow.up")
            }
            ShareLink(item: bundle.caseJSONURL) {
              Label("Share case JSON", systemImage: "curlybraces.square")
            }
            ShareLink(item: bundle.manifestURL) {
              Label("Share checksum manifest", systemImage: "checkmark.shield")
            }
          }
        }
      }
    }
    .navigationTitle("Verification & report")
  }

  @ViewBuilder private func verificationForm(_ revision: MechanicDiagnosticCaseRevision)
    -> some View
  {
    Section("Verification outcome") {
      Picker("Outcome", selection: $verification.outcome) {
        ForEach(MechanicDiagnosticVerificationOutcome.allCases, id: \.self) { outcome in
          Text(outcome.displayName).tag(outcome)
        }
      }
      if verification.outcome == .notPerformed {
        TextField(
          "Reason verification was not performed", text: $verification.reason, axis: .vertical)
      } else {
        TextField("Verification method", text: $verification.method, axis: .vertical)
        TextField("Notes (optional)", text: $verification.reason, axis: .vertical)
        Text("Select the evidence used to verify the outcome.")
          .font(.caption)
          .foregroundStyle(.secondary)
        ForEach(revision.evidence) { evidence in
          Toggle(
            evidence.description,
            isOn: Binding(
              get: { verification.evidenceIDs.contains(evidence.evidenceID) },
              set: { selected in
                if selected {
                  verification.evidenceIDs.insert(evidence.evidenceID)
                } else {
                  verification.evidenceIDs.remove(evidence.evidenceID)
                }
              }))
        }
      }
      Button("Close with verification") {
        perform { try workspace.closeCase(verification, caseID: caseID) }
      }
      .buttonStyle(.borderedProminent)
    }
  }

  private func perform(_ operation: () throws -> Void) {
    do { try operation() } catch { workspace.operationError = error.localizedDescription }
  }
}

private struct LabeledTextEditor: View {
  let title: String
  @Binding var text: String
  var minimumHeight: CGFloat = 70

  var body: some View {
    VStack(alignment: .leading, spacing: 5) {
      Text(title).font(.caption).foregroundStyle(.secondary)
      TextEditor(text: $text)
        .frame(minHeight: minimumHeight)
        .scrollContentBackground(.hidden)
        .padding(6)
        .background(.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }
  }
}

private struct WorkspaceMessage: View {
  let text: String
  let isError: Bool
  let dismiss: () -> Void

  var body: some View {
    HStack(spacing: 10) {
      Image(systemName: isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
      Text(text).font(.footnote)
      Spacer()
      Button("Dismiss", action: dismiss).font(.caption)
    }
    .foregroundStyle(isError ? Color.white : Color.primary)
    .padding(10)
    .background(isError ? AnyShapeStyle(Color.red) : AnyShapeStyle(.thinMaterial))
  }
}
