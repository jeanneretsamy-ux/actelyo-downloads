param([string]$Executable,[Parameter(Mandatory=$true)][string]$ExpectedIcon,[string]$ProofDirectory,[switch]$SelfTest,[string]$DifferentIcon,[string]$Product='Actelyo RAG')
$ErrorActionPreference='Stop'
Add-Type -ReferencedAssemblies System.Drawing,System.Windows.Forms -TypeDefinition @'
using System;
using System.Drawing;
using System.Runtime.InteropServices;
using System.Text;
public static class ActelyoRuntimeIcon {
 delegate bool EnumWindowsProc(IntPtr hwnd,IntPtr state);
 [DllImport("user32.dll")] static extern bool EnumWindows(EnumWindowsProc callback,IntPtr state);
 [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr hwnd,out uint pid);
 [DllImport("user32.dll",CharSet=CharSet.Unicode)] static extern int GetWindowText(IntPtr hwnd,StringBuilder text,int count);
 [DllImport("user32.dll",EntryPoint="GetClassLongPtrW")] static extern IntPtr GetClassLongPtr(IntPtr hwnd,int index);
 [DllImport("user32.dll")] static extern bool PostMessage(IntPtr hwnd,uint message,IntPtr w,IntPtr l);
 public static IntPtr LastWindow=IntPtr.Zero;
 [DllImport("user32.dll",CharSet=CharSet.Unicode)] static extern uint PrivateExtractIcons(string file,int index,int width,int height,IntPtr[] icons,uint[] ids,uint count,uint flags);
 [DllImport("user32.dll")] static extern bool DestroyIcon(IntPtr icon);
 [DllImport("user32.dll")] static extern IntPtr SendMessage(IntPtr hwnd,uint msg,IntPtr w,IntPtr l);
 public static IntPtr Extract(string file,int width) {IntPtr[] icons=new IntPtr[1];uint[] ids=new uint[1];PrivateExtractIcons(file,0,width,width,icons,ids,1,0);if(icons[0]==IntPtr.Zero)throw new Exception("Reference icon missing");return icons[0];}
 public static void Release(IntPtr icon){DestroyIcon(icon);}
 public static IntPtr WindowIcon(IntPtr hwnd){IntPtr icon=SendMessage(hwnd,0x7f,(IntPtr)1,IntPtr.Zero);if(icon==IntPtr.Zero)icon=SendMessage(hwnd,0x7f,(IntPtr)2,IntPtr.Zero);if(icon==IntPtr.Zero)icon=GetClassLongPtr(hwnd,-14);return icon;}
 public static IntPtr FindWindowIcon(int processId,string product){IntPtr found=IntPtr.Zero;EnumWindows(delegate(IntPtr hwnd,IntPtr state){uint pid;GetWindowThreadProcessId(hwnd,out pid);if(pid!=(uint)processId)return true;StringBuilder title=new StringBuilder(512);GetWindowText(hwnd,title,512);if(title.ToString().IndexOf(product,StringComparison.OrdinalIgnoreCase)<0)return true;IntPtr icon=WindowIcon(hwnd);if(icon==IntPtr.Zero)return true;LastWindow=hwnd;found=icon;return false;},IntPtr.Zero);return found;}
 public static void CloseSyntheticWindow(){if(LastWindow!=IntPtr.Zero)PostMessage(LastWindow,0x10,IntPtr.Zero,IntPtr.Zero);}
 public static void HiddenWindowTest(string file){IntPtr expected=Extract(file,32);try{using(System.Windows.Forms.Form form=new System.Windows.Forms.Form())using(Icon icon=(Icon)Icon.FromHandle(expected).Clone()){form.Text="Actelyo synthetic icon QA";form.Icon=icon;IntPtr hwnd=form.Handle;IntPtr actual=FindWindowIcon(System.Diagnostics.Process.GetCurrentProcess().Id,form.Text);if(actual==IntPtr.Zero||Compare(actual,file,null)!=0)throw new Exception("Hidden native window icon not matched");}}finally{Release(expected);}}
 public static int Compare(IntPtr actual,string file,string output){
  using(Icon live=(Icon)Icon.FromHandle(actual).Clone())using(Bitmap a=live.ToBitmap()){
   IntPtr expected=Extract(file,a.Width);
   try{using(Icon reference=(Icon)Icon.FromHandle(expected).Clone())using(Bitmap b=reference.ToBitmap()){
    if(!String.IsNullOrEmpty(output))a.Save(output,System.Drawing.Imaging.ImageFormat.Png);
    if(a.Width!=b.Width||a.Height!=b.Height)return Int32.MaxValue;
    int changed=0;for(int y=0;y<a.Height;y++)for(int x=0;x<a.Width;x++)if(a.GetPixel(x,y).ToArgb()!=b.GetPixel(x,y).ToArgb())changed++;
    return changed;
   }}finally{Release(expected);}
  }
 }
}
'@
if($SelfTest){
 $icon=[ActelyoRuntimeIcon]::Extract((Resolve-Path -LiteralPath $ExpectedIcon).Path,32)
 try{
  if([ActelyoRuntimeIcon]::Compare($icon,(Resolve-Path -LiteralPath $ExpectedIcon).Path,$null) -ne 0){throw 'Reference does not match itself'}
  if($DifferentIcon -and [ActelyoRuntimeIcon]::Compare($icon,(Resolve-Path -LiteralPath $DifferentIcon).Path,$null) -eq 0){throw 'Different logo incorrectly accepted'}
 }finally{[ActelyoRuntimeIcon]::Release($icon)}
 [ActelyoRuntimeIcon]::HiddenWindowTest((Resolve-Path -LiteralPath $ExpectedIcon).Path)
 'PASS native icon comparison, hidden-window discovery and different-logo rejection';exit 0
}
if($env:GITHUB_ACTIONS -ne 'true'){throw 'Window test is restricted to the synthetic GitHub runner profile.'}
if(!$ProofDirectory -or !$env:RUNNER_TEMP){throw 'Runner proof directory required'}
$proof=[IO.Path]::GetFullPath($ProofDirectory);$tempRoot=[IO.Path]::GetFullPath($env:RUNNER_TEMP).TrimEnd('\')+'\'
if(!$proof.StartsWith($tempRoot,[StringComparison]::OrdinalIgnoreCase)){throw 'Proof directory must stay under RUNNER_TEMP'}
New-Item -ItemType Directory -Path $proof -Force | Out-Null
$profile=Join-Path $proof 'synthetic-profile'
$env:HERMES_DESKTOP_USER_DATA_DIR=$profile
$env:HERMES_HOME=Join-Path $proof 'synthetic-agent-home'
$process=Start-Process -FilePath $Executable -ArgumentList @("--data-dir=`"$profile`"") -WindowStyle Hidden -PassThru
try{
 $deadline=[DateTime]::UtcNow.AddSeconds(120);$handle=[IntPtr]::Zero
 while([DateTime]::UtcNow -lt $deadline){$process.Refresh();if($process.HasExited){throw 'QA app exited before window creation'};$handle=[ActelyoRuntimeIcon]::FindWindowIcon($process.Id,$Product);if($handle -ne [IntPtr]::Zero){break};Start-Sleep -Milliseconds 200}
 if($handle -eq [IntPtr]::Zero){throw 'No actual WM_GETICON surface found'}
 $different=[ActelyoRuntimeIcon]::Compare($handle,(Resolve-Path -LiteralPath $ExpectedIcon).Path,(Join-Path $proof 'window-icon.png'))
 if($different -ne 0){throw "Runtime window logo mismatch: $different pixels"}
 @{product=$Product;surface='native-window-or-class-icon';matchingPixels=$true;personalProfileUsed=$false;observedAt=(Get-Date).ToString('o')}|ConvertTo-Json|Set-Content -LiteralPath (Join-Path $proof 'window-branding.json') -Encoding UTF8
 'PASS actual installed window icon matches the product icon'
}finally{
 $process.Refresh();if(!$process.HasExited){if(!$process.CloseMainWindow()){[ActelyoRuntimeIcon]::CloseSyntheticWindow()};if(!$process.WaitForExit(10000)){Write-Warning 'Synthetic QA process is still stopping'}}
}
