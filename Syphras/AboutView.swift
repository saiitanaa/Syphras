import SwiftUI

struct AboutView: View {
    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "info.circle.fill")
                .font(.system(size: 60))
                .foregroundStyle(.blue)
            
            Text("Syphras")
                .font(.title.bold())
            
            Text("Build - v1.0.0")
                .foregroundStyle(.secondary)
            
            Divider()
            
            Text("Cross-platform app - transferring local files")
                .font(.subheadline)
                .multilineTextAlignment(.center)
                .frame(width: 250)
            
            Spacer()
        }
        .padding(30)
        .frame(width: 300, height: 350)
    }
}
