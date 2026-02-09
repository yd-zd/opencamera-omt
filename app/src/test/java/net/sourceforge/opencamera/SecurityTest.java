package net.sourceforge.opencamera;

import org.junit.Test;
import static org.junit.Assert.*;
import java.io.File;
import java.io.IOException;

public class SecurityTest {

    @Test
    public void testPathSafety() throws IOException {
        // We can pass nulls to constructor since isPathSafe doesn't use instance members.
        StorageUtils storageUtils = new StorageUtils(null, null);

        String tempDir = System.getProperty("java.io.tmpdir");
        if (tempDir == null) tempDir = "/tmp";

        // Use a subdirectory as the mock data dir
        File mockDataDir = new File(tempDir, "mockDataDir");
        String mockDataDirPath = mockDataDir.getCanonicalPath();

        // 1. Path inside data dir -> Unsafe
        File unsafeFile = new File(mockDataDir, "config.xml");
        assertFalse("File inside data dir should be unsafe",
            storageUtils.isPathSafe(unsafeFile.getAbsolutePath(), mockDataDirPath));

        // 2. Path outside data dir -> Safe
        File safeFile = new File(tempDir, "photo.jpg");
        // Ensure safeFile is actually outside mockDataDir (it should be since it's in parent)
        if (!safeFile.getCanonicalPath().startsWith(mockDataDirPath)) {
            assertTrue("File outside data dir should be safe",
                storageUtils.isPathSafe(safeFile.getAbsolutePath(), mockDataDirPath));
        }

        // 3. Traversal out of data dir -> Safe
        // /tmp/mockDataDir/../photo.jpg -> /tmp/photo.jpg
        File traversalSafe = new File(mockDataDir, "../photo.jpg");
        assertTrue("Traversal out of data dir should be safe",
            storageUtils.isPathSafe(traversalSafe.getAbsolutePath(), mockDataDirPath));

        // 4. Sibling directory with similar prefix -> Safe
        // /tmp/mockDataDirSuffix
        File siblingDir = new File(tempDir, "mockDataDirSuffix");
        String siblingDirPath = siblingDir.getAbsolutePath();
        assertTrue("Sibling dir with similar prefix should be safe",
            storageUtils.isPathSafe(siblingDirPath, mockDataDirPath));

        // 5. Nested path inside data dir -> Unsafe
        File nestedUnsafe = new File(mockDataDir, "subdir/secret.db");
        assertFalse("Nested file inside data dir should be unsafe",
            storageUtils.isPathSafe(nestedUnsafe.getAbsolutePath(), mockDataDirPath));
    }
}
