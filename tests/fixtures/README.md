# 测试夹具目录

- `sample_summary_final.json`：`tests/test_receipt.py` 使用的归档 summary 样本
  （recognition_rate 0.95、rounds/target_rounds=100）。
- `expected/`：存放“预期输出”类夹具的保留目录。`tools/secret-scan.sh` 会跳过
  该目录，因此这里可以放含**假密钥**的扫描器自测样本；当前为空。

测试用例本身都在 `tempfile.mkdtemp()` 里生成临时目录，不依赖本目录的写权限。
