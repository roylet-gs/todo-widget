//! Cross-process change signal. Every committed write posts a Darwin notification,
//! which the app observes to refresh its UI. On other platforms this is a no-op.

pub const CHANGED_NOTIFICATION: &str = "com.todowidget.db.changed";

#[cfg(target_os = "macos")]
mod imp {
    use std::ffi::{CString, c_char, c_void};

    type CFStringRef = *const c_void;
    const K_CF_STRING_ENCODING_UTF8: u32 = 0x0800_0100;

    #[link(name = "CoreFoundation", kind = "framework")]
    unsafe extern "C" {
        fn CFNotificationCenterGetDarwinNotifyCenter() -> *const c_void;
        fn CFNotificationCenterPostNotification(
            center: *const c_void,
            name: CFStringRef,
            object: *const c_void,
            user_info: *const c_void,
            deliver_immediately: u8,
        );
        fn CFStringCreateWithCString(
            alloc: *const c_void,
            c_str: *const c_char,
            encoding: u32,
        ) -> CFStringRef;
        fn CFRelease(cf: *const c_void);
    }

    pub fn post(name: &str) {
        let Ok(c) = CString::new(name) else { return };
        unsafe {
            let s = CFStringCreateWithCString(std::ptr::null(), c.as_ptr(), K_CF_STRING_ENCODING_UTF8);
            if s.is_null() {
                return;
            }
            CFNotificationCenterPostNotification(
                CFNotificationCenterGetDarwinNotifyCenter(),
                s,
                std::ptr::null(),
                std::ptr::null(),
                1,
            );
            CFRelease(s);
        }
    }
}

#[cfg(not(target_os = "macos"))]
mod imp {
    pub fn post(_name: &str) {}
}

pub fn post_changed() {
    if std::env::var_os("TODO_NO_NOTIFY").is_none() {
        imp::post(CHANGED_NOTIFICATION);
    }
}
