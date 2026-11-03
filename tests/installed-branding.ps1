[CmdletBinding()]
param([string]$InstalledJson='', [switch]$SelfTest)
$ErrorActionPreference='Stop'
$repository=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
Add-Type -AssemblyName System.Drawing
Add-Type -TypeDefinition @'
using System;
using System.Drawing;
using System.Runtime.InteropServices;
public static class ActelyoIconProof {
 [StructLayout(LayoutKind.Sequential,CharSet=CharSet.Unicode)] public struct Info {
  public IntPtr icon;public int index;public uint attributes;
  [MarshalAs(UnmanagedType.ByValTStr,SizeConst=260)]public string display;
  [MarshalAs(UnmanagedType.ByValTStr,SizeConst=80)]public string type;
 }
 [DllImport("shell32.dll",CharSet=CharSet.Unicode)]static extern IntPtr SHGetFileInfo(string file,uint attr,out Info info,uint size,uint flags);
 [DllImport("user32.dll",CharSet=CharSet.Unicode)]static extern uint PrivateExtractIcons(string file,int index,int width,int height,out IntPtr icon,out uint id,uint count,uint flags);
 [DllImport("user32.dll")]static extern bool DestroyIcon(IntPtr icon);
 public static Bitmap Extract(string file,bool shell,int size) {
  IntPtr handle=IntPtr.Zero;
  try {
   if(shell){Info info;SHGetFileInfo(file,0,out info,(uint)Marshal.SizeOf(typeof(Info)),0x100);handle=info.icon;}
   else {uint id;PrivateExtractIcons(file,0,size,size,out handle,out id,1,0);}
   if(handle==IntPtr.Zero)throw new Exception("Windows did not extract an icon: "+file);
   using(Icon icon=Icon.FromHandle(handle))return new Bitmap(icon.ToBitmap());
  }finally{if(handle!=IntPtr.Zero)DestroyIcon(handle);}
 }
 public static double Difference(Bitmap actual,Bitmap expected) {
  using(Bitmap a=new Bitmap(actual,32,32))using(Bitmap b=new Bitmap(expected,32,32)) {
   double total=0;for(int y=0;y<32;y++)for(int x=0;x<32;x++) {
    Color c=a.GetPixel(x,y),d=b.GetPixel(x,y);
    total+=Math.Abs(c.A-d.A)+Math.Abs(c.R-d.R)+Math.Abs(c.G-d.G)+Math.Abs(c.B-d.B);
   }return total/(32*32*4*255.0);
  }
 }
 public static double Hue(Bitmap image) {
  double x=0,y=0,total=0;
  using(Bitmap b=new Bitmap(image,32,32))for(int row=0;row<32;row++)for(int col=0;col<32;col++) {
   Color c=b.GetPixel(col,row);int chroma=Math.Max(c.R,Math.Max(c.G,c.B))-Math.Min(c.R,Math.Min(c.G,c.B));
   if(c.A<64||chroma<40)continue;
   double weight=chroma*c.A/(255.0*255),angle=c.GetHue()*Math.PI/180;
   x+=weight*Math.Cos(angle);y+=weight*Math.Sin(angle);total+=weight;
  }
  if(total<1)return -1000;
  return (Math.Atan2(y,x)*180/Math.PI+360)%360;
 }
 public static double HueDistance(Bitmap a,Bitmap b) {
  double x=Hue(a),y=Hue(b);if(x<0||y<0)return 360;
  double delta=Math.Abs(x-y);return Math.Min(delta,360-delta);
 }
}
'@ -ReferencedAssemblies System.Drawing
$references=@{erp='actelyo-erp.ico';llm='actelyo-llm.ico';rag='actelyo-rag.ico';'law-harness'='actelyo-law.ico';openbousic='actelyo-imperium.ico'}
$names=@{erp='Actelyo ERP Desktop.lnk';llm='Actelyo LLM Desktop.lnk';rag='Actelyo RAG Desktop.lnk';'law-harness'='Actelyo Law Harness.lnk';openbousic='Actelyo OpenBousic.lnk'}
$limit=0.12
$hueLimit=18
if($SelfTest){
 $red=[ActelyoIconProof]::Extract((Join-Path $repository '.github/branding/actelyo-llm.ico'),$false,32)
 $green=[ActelyoIconProof]::Extract((Join-Path $repository '.github/branding/actelyo-erp.ico'),$false,32)
 $blank=New-Object Drawing.Bitmap(32,32)
 try {
  if([ActelyoIconProof]::Difference($red,$red) -ne 0){throw 'Identical native icon rejected'}
  if([ActelyoIconProof]::Difference($green,$red) -le $limit){throw 'Wrong product color accepted'}
  if([ActelyoIconProof]::Difference($blank,$red) -le $limit){throw 'Empty icon accepted'}
  foreach($left in $references.Keys){foreach($right in $references.Keys){if($left -eq $right){continue}
   $a=[ActelyoIconProof]::Extract((Join-Path $repository ('.github/branding/'+$references[$left])),$false,32)
   $b=[ActelyoIconProof]::Extract((Join-Path $repository ('.github/branding/'+$references[$right])),$false,32)
   try{if([ActelyoIconProof]::Difference($a,$b) -le $limit -and [ActelyoIconProof]::HueDistance($a,$b) -le $hueLimit){throw ('Wrong product accepted: '+$left+' / '+$right)}}finally{$a.Dispose();$b.Dispose()}
  }}
  'PASS native icon identity, all 20 wrong-product swaps and missing-image rejection'
 }finally{$red.Dispose();$green.Dispose();$blank.Dispose()}
 return
}
if(-not $InstalledJson){throw 'Installed application receipt required'}
$inputData=Get-Content -LiteralPath $InstalledJson -Raw -Encoding UTF8 | ConvertFrom-Json
$out=Join-Path $inputData.reportDirectory 'branding';New-Item -ItemType Directory -Path $out -Force | Out-Null
$report=[ordered]@{schemaVersion=1;status='running';catalogRevision=$inputData.catalog.revision;sourceCommit=(& git -C $repository rev-parse HEAD);scope='Unmodified public installers; native Windows icons and fresh desktop/Start menu shortcuts, with no repair before measurement.';applications=@()}
$shell=New-Object -ComObject WScript.Shell
$tiles=New-Object 'System.Collections.Generic.List[object]'
foreach($app in $inputData.applications){
 if(-not $references.ContainsKey($app.id)){continue}
 $row=[ordered]@{id=$app.id;version=$app.version;status='running';checks=@()}
 $expected=$null
 try {
  $expected=[ActelyoIconProof]::Extract((Join-Path $repository ('.github/branding/'+$references[$app.id])),$false,32)
  $item=$inputData.catalog.items | Where-Object {$_.id -eq $app.id}
  $setup=Join-Path $inputData.modelsDirectory $item.file
  # Repeat SHA verification so icon evidence is bound to the catalogued public binary.
  if((Get-FileHash -LiteralPath $setup -Algorithm SHA256).Hash -ne $item.sha256){throw 'Installer hash differs from catalogue'}
  $row.installerSha256=$item.sha256
  $paths=@(@{kind='installer';file=$setup;shell=$false},@{kind='executable';file=$app.executable;shell=$false})
  foreach($place in @(@{kind='desktop';roots=@([Environment]::GetFolderPath('Desktop'),[Environment]::GetFolderPath('CommonDesktopDirectory'))},@{kind='start-menu';roots=@([Environment]::GetFolderPath('Programs'),[Environment]::GetFolderPath('CommonPrograms'))})){
   $found=@(foreach($root in $place.roots){if($root -and (Test-Path -LiteralPath $root)){Get-ChildItem -LiteralPath $root -Filter $names[$app.id] -File -Recurse}})
   if($found.Count -ne 1){throw ('Expected one '+$place.kind+' shortcut; got '+$found.Count)}
   $link=$shell.CreateShortcut($found[0].FullName)
   if([IO.Path]::GetFullPath($link.TargetPath) -ne [IO.Path]::GetFullPath($app.executable)){throw ('Wrong '+$place.kind+' shortcut target')}
   $paths+=@{kind=$place.kind;file=$found[0].FullName;shell=$true;target=$link.TargetPath;iconLocation=$link.IconLocation}
  }
  foreach($entry in $paths){
   $bitmap=$null
   try {
    $bitmap=[ActelyoIconProof]::Extract($entry.file,$entry.shell,32)
    $image=Join-Path $out ($app.id+'-'+$entry.kind+'.png');$bitmap.Save($image,[Drawing.Imaging.ImageFormat]::Png)
    $difference=[ActelyoIconProof]::Difference($bitmap,$expected)
    $hueDistance=[ActelyoIconProof]::HueDistance($bitmap,$expected)
    $check=@{kind=$entry.kind;path=$entry.file;status=$(if($difference -le $limit -and $hueDistance -le $hueLimit){'pass'}else{'fail'});image=[IO.Path]::GetFileName($image);normalizedDifference=$difference;maximumDifference=$limit;hueDistance=$hueDistance;maximumHueDistance=$hueLimit}
    if($entry.shell){$check.target=$entry.target;$check.iconLocation=$entry.iconLocation}
    $row.checks+= $check
    $tiles.Add(@{id=$app.id;kind=$entry.kind;image=$image;status=$check.status})
   }finally{if($bitmap){$bitmap.Dispose()}}
  }
  $row.status=if(@($row.checks | Where-Object {$_.status -ne 'pass'}).Count){'fail'}else{'pass'}
 }catch{$row.status='fail';$row.error=$_.Exception.Message}
 finally{if($expected){$expected.Dispose()}}
 $report.applications+= $row
 Write-Host ($row.status.ToUpper()+' branding '+$app.id+$(if($row.error){': '+$row.error}else{''}))
}
$report.status=if($report.applications.Count -eq 5 -and -not @($report.applications | Where-Object {$_.status -ne 'pass'}).Count){'pass'}else{'fail'}
$report.finishedAt=Get-Date -Format o
$report | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath (Join-Path $out 'branding.json') -Encoding UTF8
$sheet=New-Object Drawing.Bitmap(800,540);$g=[Drawing.Graphics]::FromImage($sheet);$font=New-Object Drawing.Font('Segoe UI',10)
try {
 $g.Clear([Drawing.Color]::FromArgb(238,242,247));$g.DrawString('Public Windows downloads: installer / executable / desktop / Start menu',$font,[Drawing.Brushes]::Black,10,8)
 $index=0;foreach($tile in $tiles){$x=($index%4)*200;$y=38+[math]::Floor($index/4)*100;$im=[Drawing.Image]::FromFile($tile.image)
  try{$g.DrawImage($im,($x+8),$y,56,56);$g.DrawString(($tile.id+' / '+$tile.kind),$font,[Drawing.Brushes]::Black,($x+5),($y+59));$g.DrawString($tile.status,$font,$(if($tile.status -eq 'pass'){[Drawing.Brushes]::DarkGreen}else{[Drawing.Brushes]::Red}),($x+5),($y+77))}finally{$im.Dispose()};$index++}
 $sheet.Save((Join-Path $out 'contact-sheet.png'),[Drawing.Imaging.ImageFormat]::Png)
}finally{$g.Dispose();$font.Dispose();$sheet.Dispose()}
if($report.status -ne 'pass'){throw 'Native branding QA failed. See branding/branding.json and contact-sheet.png.'}
