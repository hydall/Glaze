import type { PluginListenerHandle, PermissionState } from "@capacitor/core";
export interface NotificationPermissionStatus {
    notifications: PermissionState;
}
export interface MicrophonePermissionStatus {
    microphone: PermissionState;
}
export interface ISettings {
    title: string;
    text: string;
    subText: string;
    bigText: boolean;
    resume: boolean;
    silent: boolean;
    hidden: boolean;
    color: string;
    icon: string;
    channelName: string;
    channelDescription: string;
    allowClose: boolean;
    closeIcon: string;
    closeTitle: string;
    showWhen: boolean;
    disableWebViewOptimization: boolean;
    visibility: 'public' | 'private' | 'secret';
}
export interface BackgroundModePlugin {
    enable(settings: Partial<ISettings>): Promise<void>;
    disable(): Promise<void>;
    updateNotification(settings: Partial<ISettings>): Promise<void>;
    checkNotificationsPermission(): Promise<NotificationPermissionStatus>;
    requestNotificationsPermission(): Promise<NotificationPermissionStatus>;
    checkMicrophonePermission(): Promise<MicrophonePermissionStatus>;
    requestMicrophonePermission(): Promise<MicrophonePermissionStatus>;
    checkBatteryOptimizations(): Promise<{
        enabled: boolean;
    }>;
    requestDisableBatteryOptimizations(): Promise<{
        enabled: boolean;
    }>;
    enableWebViewOptimizations(): Promise<void>;
    disableWebViewOptimizations(): Promise<void>;
    moveToBackground(): Promise<void>;
    moveToForeground(): Promise<void>;
    isScreenOff(): Promise<{
        isScreenOff: boolean;
    }>;
    isEnabled(): Promise<{
        enabled: boolean;
    }>;
    isActive(): Promise<{
        activated: boolean;
    }>;
    wakeUp(): Promise<void>;
    unlock(): Promise<void>;
    addListener(eventName: 'appInBackground', listenerFunc: () => void): Promise<PluginListenerHandle>;
    addListener(eventName: 'appInForeground', listenerFunc: () => void): Promise<PluginListenerHandle>;
    removeAllListeners(): Promise<void>;
}
