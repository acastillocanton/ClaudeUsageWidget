# ClaudeUsageWidget - Status

## Que es

Widget nativo de macOS (WidgetKit) + app de barra de menu que muestra el uso real de Claude en tiempo real. Obtiene los datos directamente del dashboard de claude.ai.

## Lo que funciona

### Widget de macOS
- Widget en 3 tamanos: small, medium, large
- Barras de progreso coloreadas por nivel de uso (verde < 50%, amarillo < 75%, naranja < 90%, rojo >= 90%)
- Tiempo de reset para cada ventana (5h y 7d)
- Grafico de historial de uso (medium y large)
- Logo de Claude en la cabecera
- Logo de autor (castillocanton.com) como enlace en la cabecera
- Auto-refresh cada 5 minutos

### App de barra de menu
- Mini barras de progreso en la barra de estado
- Menu con datos de uso, Refresh, Reload Widget, enlace al autor, Quit
- Refresh no bloquea la UI (background thread)

### Obtencion de datos
- **Metodo principal**: API de Claude via AppleScript + Chrome
  - Busca un tab abierto en claude.ai en Chrome
  - Ejecuta `fetch('/api/organizations/{orgId}/usage')` via JavaScript
  - Obtiene porcentaje real de uso y tiempo de reset
  - Requiere: Chrome abierto con tab en claude.ai, "Permitir JavaScript desde Apple Events" activado
- **Fallback**: Lectura de ficheros JSONL locales (`~/.claude/projects/`)
  - Cuenta tokens de las sesiones de Claude Code
  - Solo captura uso de Claude Code CLI, no de claude.ai web
- **Auto-deteccion de org ID** desde `~/Library/Application Support/Claude/claude-code-sessions/`

### Datos compartidos
- La app principal (sin sandbox) obtiene datos y los guarda en `~/Library/Application Support/ClaudeUsageWidget/usage_data.json`
- El widget (con sandbox) lee ese JSON via `getpwuid(getuid())` para obtener el home real
- Config en `config.json` con limites de tokens y org ID

### Repositorio
- GitHub: https://github.com/acastillocanton/ClaudeUsageWidget
- Ultimo commit: "Fetch real usage data from Claude API via Chrome AppleScript"

## Donde nos hemos quedado

### Problema actual: Widget no aparece en la galeria

El widget desaparecio de la galeria de widgets de macOS despues de la ultima reinstalacion.

**Causa raiz**: Al firmar con `codesign --deep`, se eliminan los entitlements individuales de la extension. WidgetKit requiere `com.apple.security.app-sandbox = true` en la extension.

**Solucion aplicada** (pero no en el flujo de build):
```bash
# Firmar extension CON sus entitlements
codesign --force --sign "Apple Development: elalecu@gmail.com (3BRASFB2Q5)" \
    --entitlements "UsageWidgetExtension/UsageWidgetExtension.entitlements" \
    "/Applications/ClaudeUsageWidget.app/Contents/PlugIns/UsageWidgetExtension.appex"

# Firmar app CON sus entitlements
codesign --force --sign "Apple Development: elalecu@gmail.com (3BRASFB2Q5)" \
    --entitlements "ClaudeUsageWidget/ClaudeUsageWidget.entitlements" \
    "/Applications/ClaudeUsageWidget.app"

# Registrar
lsregister -f -R -trusted "/Applications/ClaudeUsageWidget.app"
pluginkit -a "/Applications/ClaudeUsageWidget.app/Contents/PlugIns/UsageWidgetExtension.appex"
```

**Estado**: Se ejecuto manualmente y `pluginkit -m` confirmo el registro exitoso. Falta verificar que aparece en la galeria.

**IMPORTANTE**: No se deben borrar los `*.debug.dylib` del build. El binario los referencia en modo Debug y sin ellos la app no arranca (dyld error).

## Flujo de build completo

```bash
# 1. Build
cd "/Users/usuario/Documents/00 Alejandro/03 Desarrollos/Barra Claude/ClaudeUsageWidget"
xcodebuild -project ClaudeUsageWidget.xcodeproj -scheme ClaudeUsageWidget \
    -configuration Debug build \
    DEVELOPMENT_TEAM=36773FPNUM CODE_SIGN_IDENTITY="Apple Development" CODE_SIGN_STYLE=Automatic

# 2. Copiar a /Applications (NO borrar debug.dylib)
rm -rf /Applications/ClaudeUsageWidget.app
cp -R ~/Library/Developer/Xcode/DerivedData/ClaudeUsageWidget-gzelmxpydptyckesokpotplbgmft/Build/Products/Debug/ClaudeUsageWidget.app /Applications/

# 3. Firmar con entitlements (NO usar --deep)
codesign --force --sign "Apple Development: elalecu@gmail.com (3BRASFB2Q5)" \
    --entitlements "UsageWidgetExtension/UsageWidgetExtension.entitlements" \
    "/Applications/ClaudeUsageWidget.app/Contents/PlugIns/UsageWidgetExtension.appex"

codesign --force --sign "Apple Development: elalecu@gmail.com (3BRASFB2Q5)" \
    --entitlements "ClaudeUsageWidget/ClaudeUsageWidget.entitlements" \
    "/Applications/ClaudeUsageWidget.app"

# 4. Registrar
/System/Library/Frameworks/CoreServices.framework/Versions/Current/Frameworks/LaunchServices.framework/Versions/Current/Support/lsregister -f -R -trusted "/Applications/ClaudeUsageWidget.app"

# 5. Lanzar
open /Applications/ClaudeUsageWidget.app
```

## Arquitectura de ficheros

```
ClaudeUsageWidget/
  project.yml              # xcodegen config
  ClaudeUsageWidget/       # App principal (menu bar)
    ClaudeUsageWidgetApp.swift
    ClaudeUsageWidget.entitlements  (sandbox=false)
    Info.plist             (LSUIElement=true, NSAppleEventsUsageDescription)
    Assets.xcassets/       (ClaudeLogo, AuthorLogo, AppIcon)
  UsageWidgetExtension/    # Widget extension
    UsageWidget.swift      (todas las vistas: Small, Medium, Large + Chart)
    UsageWidgetBundle.swift
    UsageWidgetExtension.entitlements  (sandbox=true + file read exception)
    Info.plist
    Assets.xcassets/       (ClaudeLogo, AuthorLogo)
  Shared/
    UsageDataShared.swift  (UsageInfo, UsageConfig, UsageFetcher, Chrome API, JSONL fallback)
```

## Credenciales y IDs

- Team ID: `36773FPNUM`
- Signing Identity: `Apple Development: elalecu@gmail.com (3BRASFB2Q5)`
- App Bundle ID: `com.alejandro.ClaudeUsageWidget`
- Extension Bundle ID: `com.alejandro.claudeusage.widget.extension`
- Org ID (Claude): `723d155b-1d53-4a10-b3b1-3b21705916cf`

## Requisitos para el usuario

1. Chrome abierto con al menos un tab en claude.ai
2. Chrome > Ver > Opciones para desarrolladores > Permitir JavaScript desde Eventos de Apple
3. Aceptar el dialogo de macOS "Claude Usage quiere controlar Google Chrome"
