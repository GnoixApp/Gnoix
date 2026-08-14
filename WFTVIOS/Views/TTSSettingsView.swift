import SwiftUI

struct TTSSettingsView: View {
    @State private var apiKey: String = ""
    @State private var showingAlert = false
    
    var body: some View {
        Form {
            Section {
                SecureField("TTS API密钥", text: $apiKey)
            } header: {
                Text("API配置")
            } footer: {
                Text("配置TTS语音合成服务的API密钥")
            }
            
            Section {
                Button("保存") {
                    if !apiKey.isEmpty {
                        SecureStore.set(apiKey, for: "TTSAPIKey")
                    } else {
                        SecureStore.removeValue(for: "TTSAPIKey")
                    }
                    showingAlert = true
                }
                .frame(maxWidth: .infinity)
            }
        }
        .navigationTitle("语音合成")
        .alert("保存成功", isPresented: $showingAlert) {
            Button("确定", role: .cancel) { }
        }
        .onAppear {
            apiKey = SecureStore.value(for: "TTSAPIKey") ?? ""
        }
    }
}

#Preview {
    TTSSettingsView()
}
