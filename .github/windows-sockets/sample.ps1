# #412: while the e2e suite runs on the Windows runner, sample its TCP sockets
# every 5 s into a CSV. Each row counts the connections by state, and names
# the listeners most TIME_WAIT sockets belong to (the process that listens on
# one end of the connection), so the log shows who opens short connections.
# Read-only: it changes no setting.
param([string]$Out)
"time,established,time_wait,close_wait,syn_sent,all,r_procs,time_wait_by_listener" | Set-Content $Out
while ($true) {
  $c = @(Get-NetTCPConnection -ErrorAction SilentlyContinue)
  $listen = @{}
  foreach ($l in $c | Where-Object State -eq "Listen") {
    $name = (Get-Process -Id $l.OwningProcess -ErrorAction SilentlyContinue).ProcessName
    $listen[[int]$l.LocalPort] = "$name"
  }
  $tw = $c | Where-Object State -eq "TimeWait"
  $by = $tw | ForEach-Object {
    if ($listen.ContainsKey([int]$_.LocalPort)) { $listen[[int]$_.LocalPort] }
    elseif ($listen.ContainsKey([int]$_.RemotePort)) { $listen[[int]$_.RemotePort] }
    else { "port " + $_.RemotePort }
  } | Group-Object | Sort-Object Count -Descending | Select-Object -First 4 | ForEach-Object { "$($_.Name):$($_.Count)" }
  $n = { param($s) @($c | Where-Object State -eq $s).Count }
  $r = @(Get-Process -Name R, Rterm, Rscript -ErrorAction SilentlyContinue).Count
  "{0},{1},{2},{3},{4},{5},{6},{7}" -f (Get-Date -Format HH:mm:ss), (& $n "Established"), (& $n "TimeWait"), (& $n "CloseWait"), (& $n "SynSent"), $c.Count, $r, ($by -join " ") | Add-Content $Out
  Start-Sleep -Seconds 5
}
