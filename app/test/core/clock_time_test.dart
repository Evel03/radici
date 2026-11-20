// Hora del día ("HH:MM", hora de Roma): la llegada de una sesión.
import 'package:flutter_test/flutter_test.dart';
import 'package:radici/core/clock_time.dart';

void main() {
  test('lee y escribe "HH:MM"', () {
    expect(ClockTime.parse('10:00').minutes, 600);
    expect(ClockTime.parse('09:30'), const ClockTime.hm(9, 30));
    expect(ClockTime.parse('00:00').minutes, 0);
    expect(ClockTime.parse('23:59').minutes, 1439);
    expect(const ClockTime.hm(9, 5).toHhMm(), '09:05');
    expect(const ClockTime(615).toString(), '10:15');
  });

  test('rechaza lo que no es una hora del día', () {
    for (final value in ['24:00', '9:30', '09:60', '10:00:00', '', 'ab:cd', ' 10:00']) {
      expect(() => ClockTime.parse(value), throwsFormatException, reason: value);
      expect(ClockTime.tryParse(value), isNull, reason: value);
    }
    expect(ClockTime.tryParse(null), isNull);
    expect(ClockTime.tryParse(600), isNull);
  });

  test('sumar minutos dentro del día; fuera del día da null', () {
    expect(const ClockTime.hm(10, 0).plusMinutes(90), const ClockTime.hm(11, 30));
    expect(const ClockTime.hm(10, 0).plusMinutes(-30), const ClockTime.hm(9, 30));
    expect(const ClockTime.hm(23, 30).plusMinutes(30), isNull);
    expect(const ClockTime.hm(0, 0).plusMinutes(-1), isNull);
  });

  test('se ordena por minutos', () {
    final times = [const ClockTime.hm(11, 0), const ClockTime.hm(9, 30), const ClockTime.hm(10, 0)]
      ..sort();
    expect(times.map((t) => t.toHhMm()), ['09:30', '10:00', '11:00']);
    expect(const ClockTime.hm(10, 0).compareTo(const ClockTime(600)), 0);
  });
}
