param([string]$TestRoot=$PSScriptRoot)
$ErrorActionPreference='Stop'
Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase
$appDir=Split-Path $TestRoot -Parent
. (Join-Path $appDir 'runtime\host-layer.ps1')
. (Join-Path $appDir 'runtime\host-follow.ps1')
Add-Type -TypeDefinition @'
using System;using System.Runtime.InteropServices;
public static class WidgetFocusTestNative {
 [DllImport("user32.dll")]public static extern IntPtr GetForegroundWindow();
 [DllImport("user32.dll")]public static extern IntPtr GetDesktopWindow();
 [DllImport("user32.dll")]public static extern bool ShowWindow(IntPtr h,int command);
}
'@
$hostWindow=New-Object Windows.Window;$hostWindow.Title='Widget focus regression host'
$pet=[Windows.Markup.XamlReader]::Parse([IO.File]::ReadAllText((Join-Path $appDir 'widget.xaml'),[Text.Encoding]::UTF8))
foreach($window in @($hostWindow,$pet)){$window.ShowActivated=$false;$window.ShowInTaskbar=$false;$window.Opacity=0}
$popup=$null;$follower=$null
try{
 $hostWindow.Show();$pet.Show()
 $hostHandle=([Windows.Interop.WindowInteropHelper]::new($hostWindow)).Handle
 $petHandle=([Windows.Interop.WindowInteropHelper]::new($pet)).Handle
 $foreground=[WidgetFocusTestNative]::GetForegroundWindow()
 $result=Set-WidgetAboveHost $petHandle $hostHandle
 if(!$result.ok){throw 'Widget could not be placed above its host.'}
 if([GptWidgetZOrderNative]::GetWindowLongPtr($petHandle,-8)-ne [IntPtr]::Zero){throw 'Overlay ownership attaches the host input queue; the widget must remain independent.'}
 if([WidgetFocusTestNative]::GetForegroundWindow()-ne $foreground){throw 'Placing the widget changed the foreground window.'}
 for($n=0;$n-lt 10;$n++){$result=Set-WidgetAboveHost $petHandle $hostHandle;if(!$result.ok){throw 'Repeated layer synchronization failed.'}}
 if([GptWidgetZOrderNative]::PreviousVisible($hostHandle)-ne $petHandle){throw 'Widget no longer sits directly above the host.'}
 Write-Output 'PASS: independent overlay stays above the host without changing foreground focus'
 # Recover an existing attachment when changing modes or upgrading an active widget.
 [GptWidgetZOrderNative]::SetWindowLongPtr($petHandle,-8,$hostHandle)|Out-Null
 $result=Set-WidgetAboveHost $petHandle $hostHandle
 if([GptWidgetZOrderNative]::GetWindowLongPtr($petHandle,-8)-ne [IntPtr]::Zero){throw 'Existing host ownership was not detached.'}
 Write-Output 'PASS: existing owner attachment is removed'
 # Use real HWNDs as foreground snapshots; do not activate the user's windows.
 if(![GptWidgetZOrderNative]::FollowTopmost($petHandle,$hostHandle,$hostHandle)){throw 'An active ordinary host needs a visible independent overlay.'}
 if(![GptWidgetZOrderNative]::FollowTopmost($petHandle,$hostHandle,$petHandle)){throw 'Widget interaction lost its foreground layer.'}
 $popup=New-Object Windows.Window;$popup.Owner=$hostWindow;$popup.ShowActivated=$false;$popup.ShowInTaskbar=$false;$popup.Opacity=0;$popup.Show()
 $popupHandle=([Windows.Interop.WindowInteropHelper]::new($popup)).Handle
 if(![GptWidgetZOrderNative]::FollowTopmost($petHandle,$hostHandle,$popupHandle)){throw 'A host-owned popup lost the foreground layer.'}
 $popup.Close();$popup=$null
 $desktop=[WidgetFocusTestNative]::GetDesktopWindow()
 if([GptWidgetZOrderNative]::FollowTopmost($petHandle,$hostHandle,$desktop)){throw 'Inactive ordinary host retained foreground-only topmost.'}
 [GptWidgetZOrderNative]::SetWindowPos($hostHandle,[IntPtr](-1),0,0,0,0,0x13)|Out-Null
 if(![GptWidgetZOrderNative]::FollowTopmost($petHandle,$hostHandle,$desktop)){throw 'Overlay did not respect an explicitly topmost host.'}
 Write-Output 'PASS: foreground-only topmost follows host/widget interaction and releases for other apps'
 # Verify that the real follower still hides/restores an unowned overlay.
 [GptWidgetZOrderNative]::SetWindowPos($hostHandle,[IntPtr](-2),0,0,0,0,0x13)|Out-Null
 $follower=[GptWidgetHostFollower]::new($petHandle)
 $follower.Configure($hostHandle,0,0,1920,1080,100,100,0,0,0,'right',$true)
 [WidgetFocusTestNative]::ShowWindow($hostHandle,7)|Out-Null
 $null=$follower.Synchronize()
 if([GptWidgetZOrderNative]::IsWindowVisible($petHandle)){throw 'An unowned overlay stayed visible after its host was minimized.'}
 [WidgetFocusTestNative]::ShowWindow($hostHandle,4)|Out-Null
 $restoreForeground=[WidgetFocusTestNative]::GetForegroundWindow()
 if(!$follower.Synchronize() -or ![GptWidgetZOrderNative]::IsWindowVisible($petHandle)){throw 'An unowned overlay did not restore with its host.'}
 if([WidgetFocusTestNative]::GetForegroundWindow()-ne $restoreForeground){throw 'Follower restoration changed the foreground window.'}
 $hostWindow.Close()
 $result=Set-WidgetAboveHost $petHandle $hostHandle
 if($result.ok -or $result.reason-ne 'invalid-window'){throw 'A destroyed host was accepted for layer synchronization.'}
 Write-Output 'PASS: host minimization/restoration preserves visibility and focus; destroyed hosts are rejected'
}finally{if($follower){$follower.Dispose()};if($popup){$popup.Close()};$pet.Close();$hostWindow.Close()}
