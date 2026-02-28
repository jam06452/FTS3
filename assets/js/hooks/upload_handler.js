const UploadHandler = {
  fileInfo: null,

  mounted() {
    this.uploadedParts = []; // Store { part_number, etag }

    // File input change
    const fileInput = this.el.querySelector("#file-input");
    if (fileInput) {
      fileInput.addEventListener("change", (e) => {
        const file = e.target.files[0];
        if (file) {
          const now = new Date();
          const timestamp = now.getFullYear().toString() +
            (now.getMonth() + 1).toString().padStart(2, '0') +
            now.getDate().toString().padStart(2, '0') + '_' +
            now.getHours().toString().padStart(2, '0') +
            now.getMinutes().toString().padStart(2, '0') +
            now.getSeconds().toString().padStart(2, '0');

          const lastDot = file.name.lastIndexOf('.');
          let newName = file.name;
          if (lastDot === -1) {
            newName = `${file.name}_${timestamp}`;
          } else {
            newName = `${file.name.substring(0, lastDot)}_${timestamp}${file.name.substring(lastDot)}`;
          }

          this.fileInfo = {
            name: newName,
            size: file.size,
            file: file,
          };
          this.pushEvent("file_info", { name: newName, size: file.size });
        }
      });
    }

    // Handle events from LiveView
    this.handleEvent("start_upload", (payload) => this.uploadFile(payload));
    this.handleEvent("reassemble_and_upload", () => this.finishUpload());

    // Delegate clicks for copy/open buttons (works across re-renders)
    this.el.addEventListener("click", (e) => {
      const copyBtn = e.target.closest(".copy-url");
      const openBtn = e.target.closest(".open-url");

      if (copyBtn) {
        e.preventDefault();
        const input = this.el.querySelector('#uploaded-url');
        if (input && input.value) {
          navigator.clipboard
            .writeText(input.value)
            .then(() => {
              // optional feedback via DOM or LiveView event
              this.pushEvent('copy_success', {});
            })
            .catch((err) => {
              console.error('Copy failed', err);
              this.pushEvent('copy_failed', {});
            });
        }
      }

      if (openBtn) {
        e.preventDefault();
        const input = this.el.querySelector('#uploaded-url');
        if (input && input.value) {
          window.open(input.value, '_blank');
        }
      }
    });
  },

  async uploadFile({ s3_upload_id, s3_key }) {
    if (!this.fileInfo) {
      console.error("No file information available");
      this.pushEvent("upload_complete", { success: false, error: "No file selected" });
      return;
    }

    this.s3Data = { s3_upload_id, s3_key };
    this.uploadedParts = [];

    const file = this.fileInfo.file;
    this.pushEvent("upload_started", {});

    const defaultChunkSize = 5 * 1024 * 1024; // 5MB
    const chunkSize = parseInt(this.el.dataset.chunkSize, 10) || defaultChunkSize;
    const totalChunks = Math.ceil(file.size / chunkSize);

    let currentChunk = 0;
    const concurrency = 4;
    let hasError = false;

    const uploadNext = async () => {
      if (hasError) return;

      const i = currentChunk++;
      if (i >= totalChunks) return;

      const start = i * chunkSize;
      const end = Math.min(start + chunkSize, file.size);
      const chunk = file.slice(start, end);

      const formData = new FormData();
      formData.append("upload_id", this.el.dataset.uploadId);
      formData.append("chunk_index", i);
      formData.append("s3_upload_id", s3_upload_id);
      formData.append("s3_key", s3_key);
      formData.append("chunk_data", chunk);

      try {
        const response = await fetch("/api/upload/chunk", {
          method: "POST",
          body: formData,
          headers: {
            "X-CSRF-Token": document.querySelector('meta[name="csrf-token"]')?.content || "",
          },
        });

        if (!response.ok) {
          throw new Error(`Upload failed: ${response.statusText}`);
        }

        const data = await response.json();

        if (data.etag) {
          this.uploadedParts.push({ part_number: i + 1, etag: data.etag });
        }

        this.pushEvent("chunk_uploaded", { index: i, total: totalChunks });

        // Continue with the next chunk
        await uploadNext();
      } catch (error) {
        if (!hasError) {
          hasError = true;
          console.error("Chunk upload failed:", error);
          this.pushEvent("upload_complete", { success: false, error: `Failed to upload chunk ${i + 1}` });
        }
      }
    };

    const workers = [];
    for (let w = 0; w < Math.min(concurrency, totalChunks); w++) {
      workers.push(uploadNext());
    }

    await Promise.all(workers);
  },

  async finishUpload() {
    if (!this.fileInfo || !this.s3Data) {
      console.error("No file information available or S3 data missing");
      this.pushEvent("upload_complete", { success: false, error: "Upload information missing" });
      return;
    }

    const uploadId = this.el.dataset.uploadId;

    try {
      const response = await fetch("/api/upload/finalize", {
        method: "POST",
        body: JSON.stringify({
          upload_id: uploadId,
          filename: this.fileInfo.name,
          file_size: this.fileInfo.size,
          s3_upload_id: this.s3Data.s3_upload_id,
          s3_key: this.s3Data.s3_key,
          parts: this.uploadedParts
        }),
        headers: {
          "Content-Type": "application/json",
          "X-CSRF-Token": document.querySelector('meta[name="csrf-token"]')?.content || "",
        },
      });

      if (!response.ok) {
        throw new Error(`Finalize failed: ${response.statusText}`);
      }

      const data = await response.json();

      if (data.success) {
        this.pushEvent("upload_complete", { success: true, url: data.url });
      } else {
        this.pushEvent("upload_complete", { success: false, error: data.error || "Upload finalization failed" });
      }
    } catch (error) {
      console.error("Finalization failed:", error);
      this.pushEvent("upload_complete", { success: false, error: error.message || "Upload finalization error" });
    }
  },
};

export default UploadHandler;
