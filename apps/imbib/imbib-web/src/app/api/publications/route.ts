import { auth } from "@/app/api/auth/[...nextauth]/route"
import { PrismaClient } from "@prisma/client"
import { NextResponse } from "next/server"

const prisma = new PrismaClient()

export async function GET(request: Request) {
  const session = await auth()

  if (!session?.user?.id) {
    return NextResponse.json({ message: "Unauthorized" }, { status: 401 })
  }

  try {
    const publications = await prisma.publication.findMany({
      where: { ownerId: session.user.id },
    })
    return NextResponse.json(publications)
  } catch (error) {
    console.error("Error fetching publications:", error)
    return NextResponse.json(
      { message: "Internal Server Error" },
      { status: 500 }
    )
  }
}

export async function POST(request: Request) {
  const session = await auth()

  if (!session?.user?.id) {
    return NextResponse.json({ message: "Unauthorized" }, { status: 401 })
  }

  try {
    const body = await request.json()
    const { title, author, bibtex, ...optionalFields } = body

    if (!title || !author || !bibtex) {
      return NextResponse.json(
        { message: "Missing required fields: title, author, bibtex" },
        { status: 400 }
      )
    }

    const newPublication = await prisma.publication.create({
      data: {
        title,
        author,
        bibtex,
        owner: { connect: { id: session.user.id } },
        ...optionalFields,
      },
    })
    return NextResponse.json(newPublication, { status: 201 })
  } catch (error) {
    console.error("Error creating publication:", error)
    return NextResponse.json(
      { message: "Internal Server Error" },
      { status: 500 }
    )
  }
}
