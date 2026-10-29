// http-response 示例：把 JSON 响应中的 ads 字段改为 false。
// 对应 examples/full.conf 中的 fix-config 脚本（requires-body=true）。

const body = $response.body;

if (!body) {
  $done({});
} else {
  try {
    const obj = JSON.parse(body);
    if (obj && typeof obj === "object") {
      obj.ads = false;
      obj.patchedBy = `Aether ${$environment["aether-version"]}`;
    }
    console.log(`patched ${$request.url}`);
    $done({ body: JSON.stringify(obj) });
  } catch (e) {
    console.error(`not JSON: ${e}`);
    $done({});
  }
}
