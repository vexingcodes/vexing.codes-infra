import boto3
import json
def handler(event, _):
  print(json.dumps(event, indent=2))
  return "GOT AN EVENT"
