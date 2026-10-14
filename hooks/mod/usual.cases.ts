export const TSV =
"1700000001\tapp\tnpm test\t40000\tok\n1700000002\tapp\tnpm test\t42000\tok\n1700000003\tapp\tnpm test\t38000\tfail\n1700000004\tapp\tmake\t1000\tok\n1700000005\tapp\tmake\t3000\tok\n1700000006\tapp\tmake\t2000\tok\n1700000007\tapp\tmake\t9000\tok\n1700000008\tother\tnpm test\t999000\tok\n1700000009\tapp\tlint\t5000\tok\n1700000010\tapp\tlint\t5000\tok\n1700000011\tapp\tnpm test\t40000\n1700000012\tapp\tnpm test\tabc\tok\n1700000013\tapp\tnpm test\t40000\tok\textra\n17000000\tapp\tgo test\t1000\tok\n1700000014\tapp\tgo test\t1000\tok\n1700000015\tapp\tgo test\t1000\tok\n1700000016\tapp\tgo test\t1000\tok\n1700000017\tapp\tgo test\t1000\tok\n1700000018\tapp\tgo test\t1000\tok\n1700000019\tapp\tgo test\t1000\tok\n1700000020\tapp\tgo test\t1000\tok\n1700000021\tapp\tgo test\t1000\tok\n1700000022\tapp\tgo test\t1000\tok\n1700000023\tapp\tgo test\t1000\tok\n1700000024\tapp\tgo test\t1000\tok\n1700000025\tapp\tgo test\t1000\tok\n1700000026\tapp\tgo test\t1000\tok\n1700000027\tapp\tgo test\t1000\tok\n1700000028\tapp\tgo test\t1000\tok\n1700000029\tapp\tgo test\t1000\tok\n1700000030\tapp\tgo test\t90000\tok\n1700000031\tapp\tgo test\t90000\tok\n1700000032\tapp\tgo test\t90000\tok\n1700000033\tapp\tgo test\t90000\tok\n1700000034\tapp\tgo test\t90000\tok\n1700000035\tapp\tgo test\t90000\tok\n1700000036\tapp\tgo test\t90000\tok\n1700000037\tapp\tgo test\t90000\tok\n1700000038\tapp\tgo test\t90000\tok\n1700000039\tapp\tgo test\t90000\tok\n1700000040\tapp\tgo test\t90000\tok\n1700000041\tapp\tgo test\t9";
export const CASES: ReadonlyArray<readonly [string, string, string]> = [
  ["app", "npm test", "40"],
  ["app", "make", "2"],
  ["app", "lint", ""],
  ["other", "npm test", ""],
  ["app", "go test", "90"],
  ["", "npm test", ""],
  ["-", "npm test", ""],
  ["app", "nope", ""]
]
