import SwiftUI

struct OnboardingView: View {
    @Binding var isPresented: Bool
    @Binding var selectedEdition: AbletonEdition

    var body: some View {
        VStack(spacing: 24) {
            Text("Welcome to Ableton Smart Assistant")
                .font(.title)
                .fontWeight(.bold)

            Text("Select your Ableton Live edition")
                .font(.headline)
                .foregroundColor(.secondary)

            Picker("Ableton edition", selection: $selectedEdition) {
                ForEach(AbletonEdition.allCases) { edition in
                    Text(edition.rawValue).tag(edition)
                }
            }
            .pickerStyle(.radioGroup)
            .frame(width: 300)

            Button("Continue") {
                isPresented = false
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .padding(40)
        .frame(width: 500, height: 400)
    }
}

