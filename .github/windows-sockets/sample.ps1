# #412: while the e2e suite runs on the Windows runner, sample its TCP sockets
# every 5 s into a CSV. Each row counts the connections by state, and names
# the listeners most TIME_WAIT sockets belong to (the process that listens on
# one end of the connection), so the log shows who opens short connections.
# It also logs the nonpaged pool, the other buffer Windows reports as
# ERR_NO_BUFFER_SPACE. Read-only: it changes no setting.
param([string]$Out)
"time,established,time_wait,close_wait,syn_sent,all,r_procs,nonpaged_mb,time_wait_by_listener" | Set-Content $Out
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
  $npp = [math]::Round((Get-CimInstance Win32_PerfRawData_PerfOS_Memory).PoolNonpagedBytes / 1MB, 1)
  "{0},{1},{2},{3},{4},{5},{6},{7},{8}" -f (Get-Date -Format HH:mm:ss), (& $n "Established"), (& $n "TimeWait"), (& $n "CloseWait"), (& $n "SynSent"), $c.Count, $r, $npp, ($by -join " ") | Add-Content $Out
  Start-Sleep -Seconds 5
}
