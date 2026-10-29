// cron 示例：每天请求一次接口，状态变化时发送通知，并用 $persistentStore 记住上次结果。

const KEY = "daily-check.last-status";

function get(url) {
  return new Promise((resolve, reject) => {
    $httpClient.get({ url, timeout: 10 }, (error, response, data) => {
      if (error) reject(error);
      else resolve({ status: response.status, data });
    });
  });
}

(async () => {
  try {
    const { status } = await get("https://status.example.com/api/health");
    const last = $persistentStore.read(KEY);
    if (last !== String(status)) {
      $notification.post("服务状态变化", "", `HTTP ${last ?? "-"} → ${status}`);
      $persistentStore.write(String(status), KEY);
    }
  } catch (e) {
    console.warn(`check failed: ${e}`);
  } finally {
    $done();
  }
})();
