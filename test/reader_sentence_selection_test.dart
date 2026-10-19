import 'package:flutter_test/flutter_test.dart';

import 'package:fqapp/widgets/reader/reader_chapter_layout.dart';

/// 「长按选中一句话」的句子切分口径。
void main() {
  group('sentenceRangeInText', () {
    test('按句号切分，句末标点计入本句', () {
      const text = '第一句话。第二句话！第三句话？';
      // 0第1一2句3话4。5第6二7句8话9！10第11三12句13话14？
      expect(sentenceRangeInText(text, 8), (5, 10));
      expect(sentenceRangeInText(text, 0), (0, 5));
      expect(sentenceRangeInText(text, 11), (10, 15));
    });

    test('问号叹号与英文标点同样断句', () {
      const text = '真的吗?是的!ok;好';
      // 0真1的2吗3?4是5的6!7o8k9;10好
      expect(sentenceRangeInText(text, 1), (0, 4));
      expect(sentenceRangeInText(text, 5), (4, 7));
      expect(sentenceRangeInText(text, 8), (7, 10));
    });

    test('后随右引号计入本句', () {
      const text = '他说：“走吧。”她点点头。';
      // 0他1说2：3“4走5吧6。7”8她9点10点11头12。
      final (start, end) = sentenceRangeInText(text, 5);
      expect(text.substring(start, end), '他说：“走吧。”');
    });

    test('起点落在前一句的收尾引号上时跳过', () {
      const text = '前一句。”后一句。';
      // 0前1一2句3。4”5后6一7句8。
      final (start, end) = sentenceRangeInText(text, 6);
      expect(text.substring(start, end), '后一句。');
    });

    test('最后一句没有句末标点时取到末尾', () {
      const text = '第一句。第二句没标点';
      expect(sentenceRangeInText(text, 6), (4, 10));
    });

    test('没有句末标点的整段视为一句', () {
      const text = '整段都没有句末标点';
      expect(sentenceRangeInText(text, 3), (0, text.length));
    });

    test('index 越界时钳制到合法范围', () {
      const text = '一句。';
      expect(sentenceRangeInText(text, 100), (0, 3));
      expect(sentenceRangeInText(text, -5), (0, 3));
    });

    test('空文本返回空范围', () {
      expect(sentenceRangeInText('', 0), (0, 0));
    });

    test('换行同样断句', () {
      const text = '第一行\n第二行';
      // 0第1一2行3\n4第5二6行
      expect(sentenceRangeInText(text, 5), (4, 7));
    });
  });
}
