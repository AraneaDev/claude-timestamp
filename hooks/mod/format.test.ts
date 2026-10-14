import { expect, test } from 'claude-code/testing'
import { formatDuration } from './format.ts'

test('formats like ct_format_duration', () => {
  expect(formatDuration(0)).toBe('0s')
  expect(formatDuration(45)).toBe('45s')
  expect(formatDuration(59.9)).toBe('59s')
  expect(formatDuration(60)).toBe('1m00s')
  expect(formatDuration(134)).toBe('2m14s')
  expect(formatDuration(3599)).toBe('59m59s')
  expect(formatDuration(3600)).toBe('1h00m')
  expect(formatDuration(3780)).toBe('1h03m')
  expect(formatDuration(-5)).toBe('0s')
  expect(formatDuration(Number.NaN)).toBe('0s')
})
