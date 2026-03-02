# get-site-id.ps1 — Query Pangolin DB for site info
# Run from PowerShell: .\get-site-id.ps1

param(
    [string]$VpsUser = "linuxuser",
    [string]$VpsHost = "108.61.119.92"
)

$VPS = "${VpsUser}@${VpsHost}"

# Write the node script to a local temp file — avoids all quoting issues
$nodeScript = @'
const db = require('better-sqlite3')('/app/config/db/db.sqlite');
const sites = db.prepare('SELECT siteId, name, orgId FROM sites').all();
const newts = db.prepare('SELECT id as newtId, siteId FROM newt').all();
console.log('=== SITES ===');
sites.forEach(s => {
  const n = newts.find(n => n.siteId === s.siteId);
  console.log('  siteId : ' + s.siteId);
  console.log('  name   : ' + s.name);
  console.log('  orgId  : ' + s.orgId);
  console.log('  newtId : ' + (n ? n.newtId : 'none'));
  console.log('');
});
db.close();
'@

$localScript = [System.IO.Path]::Combine($env:TEMP, "pangolin-query.cjs")
[System.IO.File]::WriteAllText($localScript, $nodeScript, [System.Text.Encoding]::UTF8)

Write-Host "Uploading query script to VPS..."
scp $localScript "${VPS}:/tmp/pangolin-query.cjs"
if ($LASTEXITCODE -ne 0) { Write-Error "SCP failed"; exit 1 }

Write-Host "Running query inside Pangolin container..."
ssh $VPS @"
sudo docker cp /tmp/pangolin-query.cjs pangolin:/app/pangolin-query.cjs && \
sudo docker exec pangolin node /app/pangolin-query.cjs; \
sudo docker exec pangolin rm -f /app/pangolin-query.cjs 2>/dev/null; \
rm -f /tmp/pangolin-query.cjs
"@

Remove-Item $localScript -ErrorAction SilentlyContinue
