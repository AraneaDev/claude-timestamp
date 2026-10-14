import { expect, test } from 'claude-code/testing'
import { CASES } from './cmdkey.cases.ts'
import { cmdKey } from './cmdkey.ts'

test('matches ct_cmdkey on every shared case', () => {
  for (const [command, key] of CASES) expect([command, cmdKey(command)]).toEqual([command, key])
})

test('a non-string has no key', () => {
  expect(cmdKey(null)).toBe('')
  expect(cmdKey(42)).toBe('')
})

test('at most 60 characters', () => {
  expect(cmdKey('x'.repeat(200))).toHaveLength(60)
})

test('thousands of words, two kept', () => {
  const long = 'git add' + Array.from({ length: 3000 }, (_, i) => ` f${i + 1}`).join('')
  expect(cmdKey(long)).toBe('git add f1')
})
