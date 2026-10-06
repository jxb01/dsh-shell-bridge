param([string]$Greeting = '你好')
Write-Output "$Greeting, 世界"
Write-Output ('cwd: ' + (Get-Location).Path)
ipconfig | Select-String '适配器' -SimpleMatch | Select-Object -First 1
python -c "print('python中文输出')"
node -e "console.log('node中文')"
