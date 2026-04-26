#!/bin/bash
mkdir -p ~/immortalwrt/package/utils/util-linux/patches
cat > ~/immortalwrt/package/utils/util-linux/patches/001-define-AT_HANDLE_FID.patch << 'EOF'
--- a/sys-utils/nsenter.c
+++ b/sys-utils/nsenter.c
@@ -52,6 +52,13 @@
 #include "all-io.h"
 #include "namespace.h"
 
+/* musl does not define AT_HANDLE_FID */
+#ifndef AT_HANDLE_FID
+#define AT_HANDLE_FID		0x200	/* file handle needed */
+#endif
+
 #ifndef NS_GET_NSTYPE
 # define NS_GET_NSTYPE		_IO(0xb7, 0x3)
 #endif
EOF