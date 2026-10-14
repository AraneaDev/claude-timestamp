import { expect, test } from 'claude-code/testing'
import { CASES, TSV } from './usual.cases.ts'
import { usualSeconds } from './usual.ts'

test('matches ct_command_usual on every shared case', () => {
  for (const [project, key, want] of CASES) {
    const got = usualSeconds(TSV, project, key)
    expect([project, key, got === undefined ? '' : String(got)]).toEqual([project, key, want])
  }
})

test('an undefined project or an empty file has no usual time', () => {
  expect(usualSeconds(TSV, undefined, 'npm test')).toBeUndefined()
  expect(usualSeconds('', 'app', 'npm test')).toBeUndefined()
})

test('a CRLF file is read like bash reads it', () => {
  expect(usualSeconds(TSV.replaceAll('\n', '\r\n'), 'app', 'npm test')).toBeUndefined()
})
