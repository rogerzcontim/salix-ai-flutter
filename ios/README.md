# SALIX AI — iOS

## Build sem Mac

Use Codemagic ou GitHub Actions. Veja `C:\Users\cw\Desktop\IOS_INSTALL.md` para passo a passo completo.

Resumo:
1. `git push` para um repo GitHub privado
2. Codemagic detecta `codemagic.yaml` e roda workflow `ios-adhoc-unsigned`
3. Baixa o `.ipa` via Codemagic dashboard
4. Instala via AltStore (Windows) com Apple ID grátis (renova a cada 7 dias)

## Permissões

Ver `ios/Runner/Info.plist`:
- NSCameraUsageDescription
- NSPhotoLibraryUsageDescription
- NSPhotoLibraryAddUsageDescription
- NSMicrophoneUsageDescription
- NSSpeechRecognitionUsageDescription
- NSDocumentsFolderUsageDescription

## Bundle ID

`ai.ironedge.salix` (Display: `SALIX AI`, versão 1.2.0+10)

## Deployment target

iOS 14.0+ (configurado em `ios/Podfile` ou `Runner.xcodeproj`)
