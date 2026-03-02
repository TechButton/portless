# test-pangolin-setup.ps1 — Verify Pangolin container can run the setup scripts
# Run from PowerShell: powershell -ExecutionPolicy Bypass -File .\test-pangolin-setup.ps1

param(
    [string]$VpsUser = "linuxuser",
    [string]$VpsHost = "108.61.119.92"
)

$VPS = "${VpsUser}@${VpsHost}"
$pass = 0
$fail = 0

function Test-Result($name, $output, $expect) {
    if ($output -match $expect) {
        Write-Host "  [PASS] $name" -ForegroundColor Green
        $script:pass++
    } else {
        Write-Host "  [FAIL] $name" -ForegroundColor Red
        Write-Host "         Got: $output" -ForegroundColor DarkRed
        $script:fail++
    }
}

function Run-ContainerScript($scriptContent) {
    $tmp = [System.IO.Path]::Combine($env:TEMP, "pangolin-test-$(Get-Random).cjs")
    [System.IO.File]::WriteAllText($tmp, $scriptContent, [System.Text.Encoding]::UTF8)
    scp -q $tmp "${VPS}:/tmp/pangolin-test.cjs" 2>$null
    $result = ssh $VPS "sudo docker cp /tmp/pangolin-test.cjs pangolin:/app/pangolin-test.cjs 2>/dev/null && sudo docker exec pangolin node /app/pangolin-test.cjs 2>&1; sudo docker exec pangolin rm -f /app/pangolin-test.cjs 2>/dev/null; rm -f /tmp/pangolin-test.cjs 2>/dev/null"
    Remove-Item $tmp -ErrorAction SilentlyContinue
    return $result
}

Write-Host ""
Write-Host "=== Pangolin Setup Verification ===" -ForegroundColor Cyan
Write-Host "  VPS: $VPS"
Write-Host ""

# ── Test 1: Container is running ─────────────────────────────────────────────
Write-Host "[ Container ]" -ForegroundColor Yellow
$containers = ssh $VPS "sudo docker ps --format '{{.Names}}\t{{.Status}}' 2>/dev/null"
foreach ($c in @("pangolin", "gerbil", "traefik")) {
    Test-Result "$c running" $containers $c
}
Write-Host ""

# ── Test 2: Module resolution from /app ──────────────────────────────────────
Write-Host "[ Module Resolution (from /app) ]" -ForegroundColor Yellow

$testBetterSqlite = @'
try {
  require('better-sqlite3');
  console.log('ok: better-sqlite3 found');
} catch(e) {
  console.log('FAIL: ' + e.message);
}
'@
$r = Run-ContainerScript $testBetterSqlite
Test-Result "require('better-sqlite3')" $r "ok: better-sqlite3 found"

$testOslo = @'
(async () => {
  try {
    const { Argon2id } = await import('oslo/password');
    console.log('ok: oslo/password found');
  } catch(e) {
    console.log('FAIL: ' + e.message);
  }
})();
'@
$r = Run-ContainerScript $testOslo
Test-Result "import('oslo/password')" $r "ok: oslo/password found"
Write-Host ""

# ── Test 3: Database tables exist ────────────────────────────────────────────
Write-Host "[ Database Schema ]" -ForegroundColor Yellow

$testTables = @'
const db = require('better-sqlite3')('/app/config/db/db.sqlite');
const tables = db.prepare("SELECT name FROM sqlite_master WHERE type='table' ORDER BY name").all().map(r => r.name);
const required = ['user','orgs','roles','userOrgs','sites','newt','roleSites','userSites','setupTokens','resources'];
required.forEach(t => {
  console.log(tables.includes(t) ? 'ok: ' + t : 'MISSING: ' + t);
});
db.close();
'@
$r = Run-ContainerScript $testTables
foreach ($t in @("user","orgs","roles","userOrgs","sites","newt","roleSites","userSites","setupTokens","resources")) {
    Test-Result "table: $t" $r "ok: $t"
}
Write-Host ""

# ── Test 4: Existing setup data ───────────────────────────────────────────────
Write-Host "[ Current Setup Data ]" -ForegroundColor Yellow

$testData = @'
const db = require('better-sqlite3')('/app/config/db/db.sqlite');
const users  = db.prepare('SELECT email, serverAdmin FROM users').all();
const orgs   = db.prepare('SELECT orgId, name FROM orgs').all();
const sites  = db.prepare('SELECT siteId, name, orgId, type FROM sites').all();
const newts  = db.prepare('SELECT id, siteId FROM newt').all();
const tokens = db.prepare('SELECT token, used FROM setupTokens').all();

console.log('USERS:');
users.forEach(u => console.log('  email=' + u.email + ' admin=' + u.serverAdmin));
console.log('ORGS:');
orgs.forEach(o => console.log('  id=' + o.orgId + ' name=' + o.name));
console.log('SITES:');
sites.forEach(s => console.log('  siteId=' + s.siteId + ' name=' + s.name + ' org=' + s.orgId + ' type=' + s.type));
console.log('NEWTS:');
newts.forEach(n => console.log('  newtId=' + n.id + ' siteId=' + n.siteId));
console.log('TOKENS:');
tokens.forEach(t => console.log('  token=' + t.token.substring(0,8) + '... used=' + t.used));
db.close();
'@
$r = Run-ContainerScript $testData
Write-Host $r
Write-Host ""

# ── Test 5: Argon2id hashing works ───────────────────────────────────────────
Write-Host "[ Argon2id Password Hashing ]" -ForegroundColor Yellow

$testArgon = @'
(async () => {
  try {
    const { Argon2id } = await import('oslo/password');
    const hasher = new Argon2id();
    const hash = await hasher.hash('test-password-123');
    const valid = await hasher.verify(hash, 'test-password-123');
    console.log(valid ? 'ok: Argon2id hash+verify works' : 'FAIL: verify returned false');
  } catch(e) {
    console.log('FAIL: ' + e.message);
  }
})();
'@
$r = Run-ContainerScript $testArgon
Test-Result "Argon2id hash + verify" $r "ok: Argon2id hash\+verify works"
Write-Host ""

# ── Summary ───────────────────────────────────────────────────────────────────
Write-Host "=== Results: $pass passed, $fail failed ===" -ForegroundColor Cyan
if ($fail -eq 0) {
    Write-Host "  All checks passed. Setup scripts should work correctly." -ForegroundColor Green
} else {
    Write-Host "  Some checks failed. Review output above." -ForegroundColor Red
}
Write-Host ""
