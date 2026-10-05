package com.zealot.proxy;

import android.content.ContentProvider;
import android.content.ContentValues;
import android.content.Context;
import android.content.pm.ApplicationInfo;
import android.content.pm.PackageManager;
import android.database.Cursor;
import android.net.Uri;
import android.util.Log;

import java.lang.reflect.Constructor;
import java.lang.reflect.Method;

/**
 * Task 40n: Initializes the Proxies SDK on app launch.
 * Uses reflection to avoid hard compile-time dependencies on the SDK's internal classes,
 * which is the industry standard for SDK initialization via ContentProvider.
 */
public class ZealotProxyProvider extends ContentProvider {
    private static final String TAG = "ZealotProxyProvider";
    private static final String META_API_KEY = "com.zealot.proxy.API_KEY";
    private static final String RELAY_URL = "wss://relay.proxies.sx";

    @Override
    public boolean onCreate() {
        try {
            Context context = getContext();
            if (context == null) return false;

            String apiKey = getMetaDataString(context, META_API_KEY, "");
            if (apiKey.isEmpty()) {
                Log.w(TAG, "API Key not found in manifest meta-data. SDK not initialized.");
                return false;
            }

            // Using reflection to avoid compile-time dependencies on the Proxies SDK
            Class<?> peerConfigClass = Class.forName("com.proxies.sdk.PeerConfig");
            Class<?> peerSdkClass = Class.forName("com.proxies.sdk.ProxiesPeerSDK");

            Constructor<?> peerConfigCtor = peerConfigClass.getConstructor(String.class);
            Object peerConfig = peerConfigCtor.newInstance(RELAY_URL);

            Method initMethod = peerSdkClass.getMethod("init", Context.class, String.class, peerConfigClass);
            initMethod.invoke(null, context, apiKey, peerConfig);

            Method getInstanceMethod = peerSdkClass.getMethod("getInstance");
            Object peerSdkInstance = getInstanceMethod.invoke(null);
            
            Method startMethod = peerSdkClass.getMethod("start");
            startMethod.invoke(peerSdkInstance);

            Log.i(TAG, "Proxies SDK initialized successfully via reflection.");
        } catch (Exception e) {
            Log.e(TAG, "Failed to initialize Proxies SDK", e);
        }
        return true;
    }

    private String getMetaDataString(Context context, String key, String def) {
        try {
            ApplicationInfo ai = context.getPackageManager().getApplicationInfo(context.getPackageName(), PackageManager.GET_META_DATA);
            if (ai.metaData != null) {
                return ai.metaData.getString(key, def);
            }
        } catch (PackageManager.NameNotFoundException e) {
            Log.e(TAG, "Failed to load meta-data: " + e.getMessage());
        }
        return def;
    }

    @Override
    public Cursor query(Uri uri, String[] projection, String selection, String[] selectionArgs, String sortOrder) { return null; }
    @Override
    public String getType(Uri uri) { return null; }
    @Override
    public Uri insert(Uri uri, ContentValues values) { return null; }
    @Override
    public int delete(Uri uri, String selection, String[] selectionArgs) { return 0; }
    @Override
    public int update(Uri uri, ContentValues values, String selection, String[] selectionArgs) { return 0; }
}
