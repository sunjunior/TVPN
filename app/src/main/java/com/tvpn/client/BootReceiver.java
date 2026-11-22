package com.tvpn.client;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.os.Build;

/**
 * 开机自启：BOOT_COMPLETED 时直接拉起前台 VpnService。
 * 首次使用仍需在 MainActivity 中授权 VPN；授权会被系统记住。
 */
public class BootReceiver extends BroadcastReceiver {
    @Override
    public void onReceive(Context context, Intent intent) {
        String action = intent == null ? null : intent.getAction();
        if (!Intent.ACTION_BOOT_COMPLETED.equals(action)
                && !"android.intent.action.QUICKBOOT_POWERON".equals(action)
                && !"com.htc.intent.action.QUICKBOOT_POWERON".equals(action)) {
            return;
        }
        Intent svc = new Intent(context, EsimVpnService.class);
        if (Build.VERSION.SDK_INT >= 26) {
            context.startForegroundService(svc);
        } else {
            context.startService(svc);
        }
    }
}
