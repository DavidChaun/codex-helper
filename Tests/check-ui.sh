#!/bin/sh
# Render the real AppKit views using isolated preferences; never start the proxy.
set -eu
cd "$(dirname "$0")/.."
mkdir -p .build/ui-check
python3 - <<'PY'
from pathlib import Path
source = Path('CodexQuotaBar.swift').read_text().split('@main\nstruct CodexHelperMain')[0].replace('startingUpdater: true', 'startingUpdater: false')
source += '''
extension AppDelegate {
    func setUsageForUICheck(_ snapshot: CodexTokenUsageSnapshot, range: DateInterval) {
        tokenUsage = snapshot
        tokenUsageRange = range
    }
}
'''
Path('.build/ui-check/Views.swift').write_text(source)
PY
swiftc -swift-version 5 -target arm64-apple-macosx15.0 -module-cache-path .build/swift-cache \
  -F Vendor/Sparkle -framework AppKit -framework Network -framework Sparkle \
  -Xlinker -rpath -Xlinker "$(pwd)/Vendor/Sparkle" \
  .build/ui-check/Views.swift Tests/UI.swift CodexTokenUsage.swift CodexUsageSync.swift CodexResponseTiming.swift \
  WorkBuddyAccountPool.swift WorkBuddyClient.swift WorkBuddyProxy.swift ProxyDebugLog.swift \
  TraeClient.swift TraeAccountPool.swift -o .build/ui-check/check-ui
.build/ui-check/check-ui
