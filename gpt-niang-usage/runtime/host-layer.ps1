if(!('GptWidgetZOrderNative' -as [type])){
Add-Type -TypeDefinition @'
using System;using System.Runtime.InteropServices;
public static class GptWidgetZOrderNative {
 [DllImport("user32.dll")]public static extern IntPtr GetWindow(IntPtr h,uint command);
 [DllImport("user32.dll")]public static extern bool IsWindow(IntPtr h);
 [DllImport("user32.dll")]public static extern bool IsWindowVisible(IntPtr h);
 [DllImport("user32.dll")]public static extern bool IsIconic(IntPtr h);
 [DllImport("user32.dll")]public static extern IntPtr GetForegroundWindow();
 [DllImport("user32.dll")]static extern IntPtr GetAncestor(IntPtr h,uint flags);
 [DllImport("user32.dll")]static extern uint GetWindowThreadProcessId(IntPtr h,out uint processId);
 [DllImport("user32.dll",EntryPoint="GetWindowLongPtrW")]public static extern IntPtr GetWindowLongPtr(IntPtr h,int index);
 [DllImport("user32.dll",EntryPoint="SetWindowLongPtrW")]public static extern IntPtr SetWindowLongPtr(IntPtr h,int index,IntPtr value);
 [DllImport("user32.dll")]public static extern bool SetWindowPos(IntPtr h,IntPtr after,int x,int y,int width,int height,uint flags);
 [DllImport("dwmapi.dll")]static extern int DwmGetWindowAttribute(IntPtr h,int attribute,out uint value,int size);
 public static bool Topmost(IntPtr h){return (GetWindowLongPtr(h,-20).ToInt64()&8)!=0;}
 public static bool FollowTopmost(IntPtr widget,IntPtr host,IntPtr foreground){
  if(Topmost(host)||GetAncestor(foreground,3)==host)return true;
  uint widgetPid,foregroundPid;
  GetWindowThreadProcessId(widget,out widgetPid);GetWindowThreadProcessId(foreground,out foregroundPid);
  return widgetPid!=0&&widgetPid==foregroundPid;
 }
 public static bool VisibleSurface(IntPtr h){uint cloaked;return IsWindowVisible(h)&&(DwmGetWindowAttribute(h,14,out cloaked,4)!=0||cloaked==0);}
 public static IntPtr PreviousVisible(IntPtr h){
  IntPtr prior=GetWindow(h,3);for(int n=0;n<10000&&prior!=IntPtr.Zero;n++){
   if(VisibleSurface(prior))return prior;prior=GetWindow(prior,3);
  }return IntPtr.Zero;
 }
}
'@
}
$script:gptZOrderBands=@{}
function Set-WidgetDesktopLayer([IntPtr]$Widget,[bool]$Topmost=$true){
  # A desktop pet must not be owned (and destroyed or minimized) by the chat window.
  if([GptWidgetZOrderNative]::GetWindowLongPtr($Widget,-8)-ne [IntPtr]::Zero){
    [GptWidgetZOrderNative]::SetWindowLongPtr($Widget,-8,[IntPtr]::Zero)|Out-Null
  }
  if([GptWidgetZOrderNative]::Topmost($Widget)-ne $Topmost){
    $band=if($Topmost){[IntPtr](-1)}else{[IntPtr](-2)}
    [GptWidgetZOrderNative]::SetWindowPos($Widget,$band,0,0,0,0,0x13)|Out-Null
  }
}
function Set-WidgetAboveHost([IntPtr]$Widget,[IntPtr]$HostWindowHandle){
  if(![GptWidgetZOrderNative]::IsWindow($Widget) -or ![GptWidgetZOrderNative]::IsWindow($HostWindowHandle)){
    return [pscustomobject]@{ok=$false;changed=$false;reason='invalid-window'}
  }
  if(![GptWidgetZOrderNative]::VisibleSurface($HostWindowHandle) -or [GptWidgetZOrderNative]::IsIconic($HostWindowHandle)){
    return [pscustomobject]@{ok=$false;changed=$false;reason='host-not-visible'}
  }
  $key=$Widget.ToInt64().ToString();$changed=$false
  # Cross-process ownership implicitly attaches the input queues. Keeping the
  # overlay independent lets Chromium restore its content focus on activation.
  # Position and lifecycle synchronization are handled by the host follower.
  if([GptWidgetZOrderNative]::GetWindowLongPtr($Widget,-8)-ne [IntPtr]::Zero){
    [GptWidgetZOrderNative]::SetWindowLongPtr($Widget,-8,[IntPtr]::Zero)|Out-Null
    if([GptWidgetZOrderNative]::GetWindowLongPtr($Widget,-8)-ne [IntPtr]::Zero){
      return [pscustomobject]@{ok=$false;changed=$false;reason='owner-detachment-failed'}
    }
    $changed=$true
  }
  $hostBand=[GptWidgetZOrderNative]::Topmost($HostWindowHandle)
  # An independent background process cannot reliably raise a normal HWND above
  # the foreground app. Use topmost while this host/widget group is active. The
  # existing foreground-event timer returns it to the normal band for other apps.
  $followBand=[GptWidgetZOrderNative]::FollowTopmost($Widget,$HostWindowHandle,[GptWidgetZOrderNative]::GetForegroundWindow())
  $widgetBand=[GptWidgetZOrderNative]::Topmost($Widget)
  if(!$script:gptZOrderBands.ContainsKey($key) -or $script:gptZOrderBands[$key]-ne $followBand -or $widgetBand-ne $followBand){
    $band=if($followBand){[IntPtr](-1)}else{[IntPtr](-2)}
    if(![GptWidgetZOrderNative]::SetWindowPos($Widget,$band,0,0,0,0,0x13)){
      return [pscustomobject]@{ok=$false;changed=$false;reason='band-change-failed'}
    }
    $script:gptZOrderBands[$key]=$followBand;$changed=$true
  }
  if($followBand -and !$hostBand){return [pscustomobject]@{ok=$true;changed=$changed;adjacent=$false;hostTopmost=$hostBand}}
  # WPF may create invisible owner windows. Visible adjacency, rather than raw
  # HWND adjacency, avoids reordering forever against an invisible owner.
  $previous=[GptWidgetZOrderNative]::PreviousVisible($HostWindowHandle)
  if($previous-eq $Widget){return [pscustomobject]@{ok=$true;changed=$changed;adjacent=$true;hostTopmost=$hostBand}}
  $after=$previous
  if($after-eq [IntPtr]::Zero -or (!$hostBand -and [GptWidgetZOrderNative]::Topmost($after))){$after=[IntPtr]::Zero}
  if(![GptWidgetZOrderNative]::SetWindowPos($Widget,$after,0,0,0,0,0x13)){
    return [pscustomobject]@{ok=$false;changed=$changed;reason='placement-failed'}
  }
  $adjacent=[GptWidgetZOrderNative]::PreviousVisible($HostWindowHandle)-eq $Widget
  [pscustomobject]@{ok=$adjacent;changed=$true;adjacent=$adjacent;hostTopmost=$hostBand}
}
